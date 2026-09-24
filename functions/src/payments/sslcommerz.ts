/**
 * SSLCommerz integration (works as an aggregator for cards / banks / EMI /
 * many wallets). Recommended path for cards / EMI / many banks.
 *
 * Reference: https://developer.sslcommerz.com/
 *
 * Two endpoints used:
 *   - POST /gwprocess/v4/api.php            (initiate → returns GatewayPageURL + sessionkey)
 *   - POST /validator/api/validationserver.php  (validate IPN/return by val_id)
 *
 * Callable `sslczCreatePayment` is the entry point used by the Flutter client.
 */
import { onCall } from "firebase-functions/v2/https";
import { db, assertAuth } from "../admin";
import {
  errInvalidArgument,
  errFailedPrecondition,
  errInternal,
  poishaToTaka,
  takaToPoisha,
} from "../shared/security";
import { recordAudit } from "../audit/auditLog";
import { httpClient, sanitise, type CreatePaymentResult } from "./_http";

const SANDBOX = (process.env.SSLCOMMERZ_SANDBOX ?? "true") === "true";
const BASE_URL = SANDBOX ? "https://sandbox.sslcommerz.com" : "https://securepay.sslcommerz.com";
const INITIATE_PATH = SANDBOX
  ? "/gwprocess/v4/api.php"
  : "/gwprocess/v4/api.php";
const VALIDATE_PATH = SANDBOX
  ? "/validator/api/validationserver.php"
  : "/validator/api/validationserver.php";
const STORE_ID = process.env.SSLCOMMERZ_STORE_ID ?? "";
const STORE_PASSWORD = process.env.SSLCOMMERZ_STORE_PASSWORD ?? "";

function assertConfigured(): void {
  if (!STORE_ID || !STORE_PASSWORD) {
    errInternal("SSLCommerz credentials are not configured.");
  }
}

export interface InitiateParams {
  amountPoisha: number;
  tranId: string;
  successUrl: string;
  failUrl: string;
  cancelUrl: string;
  cusName: string;
  cusEmail: string;
  cusPhone: string;
  productName?: string;
}

export interface InitiateResult {
  GatewayPageURL: string;
  sessionkey: string;
}

/** Step 1: initiate — POST form-encoded body. */
export async function initiate(params: InitiateParams): Promise<InitiateResult> {
  assertConfigured();
  const amount = poishaToTaka(params.amountPoisha).toFixed(2);

  const form = new URLSearchParams({
    store_id: STORE_ID,
    store_passwd: STORE_PASSWORD,
    total_amount: amount,
    currency: "BDT",
    tran_id: params.tranId,
    success_url: params.successUrl,
    fail_url: params.failUrl,
    cancel_url: params.cancelUrl,
    cus_name: params.cusName,
    cus_email: params.cusEmail,
    cus_phone: params.cusPhone,
    cus_add1: "Bangladesh",
    cus_city: "Dhaka",
    cus_country: "Bangladesh",
    product_name: params.productName ?? "Paykari Bazar Order",
    product_category: "general",
    product_profile: "general",
    shipping_method: "NO",
  });

  const res = await httpClient({
    baseURL: BASE_URL,
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
  }).post(INITIATE_PATH, form.toString());

  if (res.data?.status !== "SUCCESS" || !res.data?.GatewayPageURL) {
    errFailedPrecondition(
      `SSLCommerz initiate failed: ${res.data?.failedreason ?? "unknown"}`,
      sanitise(res.data),
    );
  }
  return {
    GatewayPageURL: res.data.GatewayPageURL as string,
    sessionkey: res.data.sessionkey as string,
  };
}

/** Step 2: validate — called by webhook to re-verify by val_id. */
export async function validate(valId: string): Promise<Record<string, unknown>> {
  assertConfigured();
  const url = `${VALIDATE_PATH}?val_id=${encodeURIComponent(valId)}&store_id=${encodeURIComponent(
    STORE_ID,
  )}&store_passwd=${encodeURIComponent(STORE_PASSWORD)}&v=1&format=json`;
  const res = await httpClient({ baseURL: BASE_URL }).get(url);
  if (res.data?.status !== "VALID") {
    errFailedPrecondition(
      `SSLCommerz validation failed: ${res.data?.status ?? "unknown"}`,
      sanitise(res.data),
    );
  }
  return res.data as Record<string, unknown>;
}

// ----------------------------- callable ------------------------------------

export interface SslczCreatePaymentInput {
  orderId: string;
  successUrl?: string;
  failUrl?: string;
  cancelUrl?: string;
}

export const sslczCreatePayment = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const authCtx = assertAuth(req);
    const uid = authCtx.uid;
    const input = (req.data ?? {}) as Partial<SslczCreatePaymentInput>;
    const orderId = (input.orderId ?? "").toString().trim();
    if (!orderId) errInvalidArgument("orderId is required.");
    assertConfigured();

    const orderSnap = await db.doc(`orders/${orderId}`).get();
    if (!orderSnap.exists) errInvalidArgument(`Order ${orderId} not found.`);
    const order = orderSnap.data() as Record<string, unknown>;
    if (String(order.customerUid) !== uid) {
      errFailedPrecondition("Order does not belong to you.");
    }
    if (order.paymentStatus !== "unpaid") {
      errFailedPrecondition(`Order payment status is ${order.paymentStatus}.`);
    }
    const amountPoisha = Number(order.grandTotalPoisha ?? takaToPoisha(Number(order.total ?? 0)));

    const tranId = `PB-${orderId.slice(0, 12)}-${Date.now().toString(36)}`;
    const successUrl = input.successUrl ?? `https://paykaribazar.web.app/orders/${orderId}/paid`;
    const failUrl = input.failUrl ?? `https://paykaribazar.web.app/orders/${orderId}/failed`;
    const cancelUrl = input.cancelUrl ?? `https://paykaribazar.web.app/orders/${orderId}/cancelled`;

    const init = await initiate({
      amountPoisha,
      tranId,
      successUrl,
      failUrl,
      cancelUrl,
      cusName: String(order.customerName ?? "Customer"),
      cusEmail: String(order.customerEmail ?? "noreply@paykaribazar.app"),
      cusPhone: String(order.customerPhone ?? "0000000000"),
    });

    const paymentRef = db.collection("payments").doc(tranId);
    await paymentRef.set({
      id: tranId,
      provider: "sslcommerz",
      orderId,
      customerUid: uid,
      amountPoisha,
      status: "initiated",
      gatewayRef: tranId,
      sessionkey: init.sessionkey,
      gatewayUrl: init.GatewayPageURL,
      createdAt: Date.now(),
    });

    await recordAudit({
      actorUid: uid,
      action: "payment.initiated",
      targetType: "payment",
      targetId: tranId,
      after: { provider: "sslcommerz", orderId, amountPoisha },
    });

    const out: CreatePaymentResult = {
      provider: "sslcommerz",
      gatewayUrl: init.GatewayPageURL,
      paymentRefId: tranId,
      orderId,
      amountPoisha,
    };
    return out;
  },
);
