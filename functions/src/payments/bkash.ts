/**
 * bKash integration (production spec).
 *
 * Reference: https://developer.bka.sh/documentation
 *
 * Endpoints used (sandbox vs. live toggled by BKASH_SANDBOX):
 *   - POST /token/grant         (Basic auth app_key:app_secret, body username/password)
 *   - POST /create             (Bearer token)
 *   - POST /execute            (after user returns from callback)
 *   - POST /search             (verify by paymentID)
 *
 * Token is cached per-instance using TokenCache. The cache is per cold-start
 * only — bKash tokens are valid for ~59 minutes; we refresh 5 minutes early.
 *
 * Callable `bkashCreatePayment` is the only entry point the Flutter client
 * uses. It returns a `bkashURL` + `paymentID`. The user is redirected to the
 * URL; on return, the client polls `verifyPayment`.
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
import { httpClient, sanitise, TokenCache, type CreatePaymentResult } from "./_http";

const SANDBOX = (process.env.BKASH_SANDBOX ?? "true") === "true";
export const BKASH_BASE_URL = SANDBOX
  ? "https://tokenized.sandbox.bka.sh/v1.2.0-beta"
  : "https://tokenized.pay.bka.sh/v1.2.0-beta";
const TOKEN_URL = SANDBOX
  ? "https://tokenized.sandbox.bka.sh/v1.2.0-beta/tokenized/checkout/token/grant"
  : "https://tokenized.pay.bka.sh/v1.2.0-beta/tokenized/checkout/token/grant";

const APP_KEY = process.env.BKASH_APP_KEY ?? "";
const APP_SECRET = process.env.BKASH_APP_SECRET ?? "";
const USERNAME = process.env.BKASH_USERNAME ?? "";
const PASSWORD = process.env.BKASH_PASSWORD ?? "";
const CALLBACK_URL = process.env.BKASH_CALLBACK_URL ?? "";

const tokenCache = new TokenCache();

function assertConfigured(): void {
  if (!APP_KEY || !APP_SECRET || !USERNAME || !PASSWORD) {
    errInternal("bKash credentials are not configured.");
  }
  if (!CALLBACK_URL) {
    errInternal("BKASH_CALLBACK_URL is not configured.");
  }
}

/** Fetch (or return cached) bKash OAuth token. */
export async function grantToken(): Promise<string> {
  assertConfigured();
  return tokenCache.get(async () => {
    const basic = Buffer.from(`${APP_KEY}:${APP_SECRET}`).toString("base64");
    const res = await httpClient({
      baseURL: TOKEN_URL,
      headers: {
        Authorization: `Basic ${basic}`,
        username: USERNAME,
        password: PASSWORD,
      },
    }).post(
      "",
      {
        app_key: APP_KEY,
        app_secret: APP_SECRET,
      },
    );
    const token = res.data?.id_token;
    if (!token) {
      // bKash token-grant failures include `statusMessage` + `statusCode`
      // (safe) but historically also echoed fragments of the request — sanitise
      // so an `id_token` or `app_secret` never lands in the HttpsError
      // `details` field (which the Flutter client surfaces verbatim).
      errInternal(`bKash token grant failed: ${JSON.stringify(sanitise(res.data))}`);
    }
    return { token, ttlMs: 50 * 60 * 1000 };
  });
}

/** Create a bKash payment. `amountPoisha` is converted to taka on the wire. */
export async function createPayment(params: {
  amountPoisha: number;
  invoiceId: string;
  userId: string;
}): Promise<{ bkashURL: string; paymentID: string }> {
  const token = await grantToken();
  const client = httpClient({ baseURL: BKASH_BASE_URL, headers: { Authorization: token } });

  const body = {
    mode: "0011",
    payerReference: params.userId,
    callbackURL: CALLBACK_URL,
    amount: poishaToTaka(params.amountPoisha).toFixed(2),
    currency: "BDT",
    intent: "sale",
    merchantInvoiceNumber: params.invoiceId,
  };

  const res = await client.post("/create", body);
  if (res.data?.statusCode !== "0000" || !res.data?.bkashURL) {
    errFailedPrecondition(
      `bKash createPayment failed: ${res.data?.statusMessage ?? "unknown"}`,
      sanitise(res.data),
    );
  }
  return {
    bkashURL: res.data.bkashURL as string,
    paymentID: res.data.paymentID as string,
  };
}

/** Execute after the user returns from the gateway. */
export async function executePayment(paymentID: string): Promise<Record<string, unknown>> {
  const token = await grantToken();
  const client = httpClient({ baseURL: BKASH_BASE_URL, headers: { Authorization: token } });
  const res = await client.post("/execute", { paymentID });
  return res.data as Record<string, unknown>;
}

/** Search a payment (used by webhook + verifyPayment). */
export async function searchPayment(paymentID: string): Promise<Record<string, unknown>> {
  const token = await grantToken();
  const client = httpClient({ baseURL: BKASH_BASE_URL, headers: { Authorization: token } });
  const res = await client.post("/search", { paymentID });
  return res.data as Record<string, unknown>;
}

// ----------------------------- callable ------------------------------------

export interface BkashCreatePaymentInput {
  orderId: string;
  amountPoisha?: number;
}

export const bkashCreatePayment = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const authCtx = assertAuth(req);
    const uid = authCtx.uid;
    const input = (req.data ?? {}) as Partial<BkashCreatePaymentInput>;
    const orderId = (input.orderId ?? "").toString().trim();
    if (!orderId) errInvalidArgument("orderId is required.");
    assertConfigured();

    // Load the order and verify ownership + payment status.
    const orderSnap = await db.doc(`orders/${orderId}`).get();
    if (!orderSnap.exists) errInvalidArgument(`Order ${orderId} not found.`);
    const order = orderSnap.data() as Record<string, unknown>;
    if (String(order.customerUid) !== uid) {
      errFailedPrecondition("Order does not belong to you.");
    }
    if (order.paymentStatus !== "unpaid") {
      errFailedPrecondition(`Order payment status is ${order.paymentStatus}.`);
    }
    const amountPoisha =
      typeof input.amountPoisha === "number"
        ? Math.min(takaToPoisha(Number(order.total)), Math.round(input.amountPoisha))
        : Number(order.grandTotalPoisha ?? takaToPoisha(Number(order.total ?? 0)));

    const invoiceId = `PB-${orderId.slice(0, 12)}-${Date.now().toString(36)}`;
    const created = await createPayment({
      amountPoisha,
      invoiceId,
      userId: uid,
    });

    // Persist the payments doc so the webhook can correlate later.
    const paymentRef = db.collection("payments").doc(created.paymentID);
    await paymentRef.set({
      id: created.paymentID,
      provider: "bkash",
      orderId,
      customerUid: uid,
      amountPoisha,
      invoiceId,
      status: "initiated",
      gatewayRef: created.paymentID,
      bkashURL: created.bkashURL,
      createdAt: Date.now(),
    });

    await recordAudit({
      actorUid: uid,
      action: "payment.initiated",
      targetType: "payment",
      targetId: created.paymentID,
      after: { provider: "bkash", orderId, amountPoisha },
    });

    const out: CreatePaymentResult = {
      provider: "bkash",
      gatewayUrl: created.bkashURL,
      paymentRefId: created.paymentID,
      orderId,
      amountPoisha,
    };
    return out;
  },
);
