/**
 * Nagad integration (production spec).
 *
 * Reference: https://nagad.com.bd/api-docs
 *
 * Two-step flow:
 *   1. `initiate` — encrypts the payload with the merchant PRIVATE key (RSA),
 *      POSTs to `/api/dfs/check-out/initialize/<merchantId>/<datetime>`,
 *      decrypts the response with the merchant PUBLIC key, and returns
 *      `callBackUrl` + `paymentRefId`.
 *   2. `verify` — after the user is redirected back, POSTs an encrypted
 *      payload to `/api/dfs/verify/payment/<paymentRefId>` and decrypts the
 *      response. The webhook does the same to confirm server-side.
 *
 * Callable `nagadCreatePayment` is the entry point used by the Flutter client.
 *
 * NOTE: We use Node's `crypto` module — no third-party deps — so the build
 * stays light and auditable.
 */
import * as crypto from "crypto";
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

const SANDBOX = (process.env.NAGAD_SANDBOX ?? "true") === "true";
const BASE_URL = SANDBOX
  ? "https://sandbox-ssl.mynagad.com"
  : "https://api.mynagad.com";
const MERCHANT_ID = process.env.NAGAD_MERCHANT_ID ?? "";
// PEM private key, decoded from base64.
const PRIVATE_KEY_PEM = process.env.NAGAD_MERCHANT_PRIVATE_KEY
  ? Buffer.from(process.env.NAGAD_MERCHANT_PRIVATE_KEY, "base64").toString("utf8")
  : "";
const PUBLIC_KEY_PEM = process.env.NAGAD_MERCHANT_PUBLIC_KEY
  ? process.env.NAGAD_MERCHANT_PUBLIC_KEY
  : "";
const CALLBACK_URL = process.env.NAGAD_CALLBACK_URL ?? "";

function assertConfigured(): void {
  if (!MERCHANT_ID || !PRIVATE_KEY_PEM || !PUBLIC_KEY_PEM || !CALLBACK_URL) {
    errInternal("Nagad credentials are not configured.");
  }
}

/** Encrypt sensitive data with Nagad's public key (RSA + AES hybrid). */
function encryptWithPublicKey(data: string): string {
  const publicKey = crypto.createPublicKey({ key: PUBLIC_KEY_PEM, format: "pem" });
  // Nagad uses RSA/PKCS1 with AES session key (hybrid).
  const aesKey = crypto.randomBytes(32);
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv("aes-256-cbc", aesKey, iv);
  const encrypted = Buffer.concat([cipher.update(data, "utf8"), cipher.final()]);
  const encryptedAesKey = crypto.publicEncrypt(
    { key: publicKey, padding: crypto.constants.RSA_PKCS1_PADDING },
    aesKey,
  );
  return Buffer.concat([encryptedAesKey, iv, encrypted]).toString("base64");
}

/** Sign the payload with the merchant private key (RSA-SHA256). */
function signWithPrivateKey(data: string): string {
  const sign = crypto.createSign("RSA-SHA256");
  sign.update(data);
  return sign.sign(PRIVATE_KEY_PEM, "base64");
}

/** Decrypt Nagad's response (hybrid: RSA-wrapped AES key + AES payload). */
function decryptWithPrivateKey(blob: string): string {
  const buf = Buffer.from(blob, "base64");
  // First 256 bytes: RSA-encrypted AES key.
  const encryptedAesKey = buf.subarray(0, 256);
  const iv = buf.subarray(256, 256 + 16);
  const payload = buf.subarray(256 + 16);
  const privateKey = crypto.createPrivateKey({ key: PRIVATE_KEY_PEM, format: "pem" });
  const aesKey = crypto.privateDecrypt(
    { key: privateKey, padding: crypto.constants.RSA_PKCS1_PADDING },
    encryptedAesKey,
  );
  const decipher = crypto.createDecipheriv("aes-256-cbc", aesKey, iv);
  const decrypted = Buffer.concat([decipher.update(payload), decipher.final()]);
  return decrypted.toString("utf8");
}

interface InitiateResult {
  callBackUrl: string;
  paymentRefId: string;
}

/** Step 1: initiate.
 *
 * NOTE: the `params` argument is currently NOT used inside the body — the
 * Nagad `/initialize` endpoint only requires the merchant-side challenge
 * and returns a `callBackUrl` + `paymentReferenceId`. The actual payment
 * amount, invoice ID, and user ID are forwarded to Nagad at the
 * `/verify` step (see `verify()` below). The signature is kept stable so
 * the caller at `nagadCreatePayment` doesn't need to special-case the
 * Nagad provider. Renaming to `_params` to satisfy eslint's
 * `no-unused-vars` rule with the `argsIgnorePattern: '^_'` convention.
 */
// eslint-disable-next-line @typescript-eslint/no-unused-vars
export async function initiate(_params: {
  amountPoisha: number;
  invoiceId: string;
  userId: string;
}): Promise<InitiateResult> {
  assertConfigured();
  const datetime = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
  const url = `/api/dfs/check-out/initialize/${MERCHANT_ID}/${datetime}`;

  const sensitive = JSON.stringify({
    merchantId: MERCHANT_ID,
    datetime,
    challenge: crypto.randomBytes(16).toString("hex"),
  });
  const encryptedSensitive = encryptWithPublicKey(sensitive);
  const signature = signWithPrivateKey(encryptedSensitive);

  const body = {
    accountNumber: MERCHANT_ID,
    dateTime: datetime,
    sensitiveData: encryptedSensitive,
    signature,
  };

  const res = await httpClient({ baseURL: BASE_URL }).post(url, body);
  if (res.data?.status !== "Success" || !res.data?.sensitiveData) {
    errFailedPrecondition(
      `Nagad initiate failed: ${res.data?.message ?? "unknown"}`,
      sanitise(res.data),
    );
  }
  const decrypted = JSON.parse(decryptWithPrivateKey(res.data.sensitiveData)) as Record<string, unknown>;
  return {
    callBackUrl: String(decrypted.callBackUrl ?? res.data.callBackUrl ?? ""),
    paymentRefId: String(decrypted.paymentReferenceId ?? ""),
  };
}

/** Step 2: verify. */
export async function verify(
  paymentRefId: string,
  merchantOrderId: string,
  amountPoisha: number,
): Promise<Record<string, unknown>> {
  assertConfigured();
  const url = `/api/dfs/verify/payment/${paymentRefId}`;
  const sensitive = JSON.stringify({
    merchantId: MERCHANT_ID,
    orderId: merchantOrderId,
    amount: poishaToTaka(amountPoisha).toFixed(2),
    currency: "BDT",
  });
  const encryptedSensitive = encryptWithPublicKey(sensitive);
  const signature = signWithPrivateKey(encryptedSensitive);

  const body = {
    accountNumber: MERCHANT_ID,
    orderId: merchantOrderId,
    paymentReferenceId: paymentRefId,
    sensitiveData: encryptedSensitive,
    signature,
  };

  const res = await httpClient({ baseURL: BASE_URL }).post(url, body);
  if (res.data?.status !== "Success" || !res.data?.sensitiveData) {
    errFailedPrecondition(
      `Nagad verify failed: ${res.data?.message ?? "unknown"}`,
      sanitise(res.data),
    );
  }
  return JSON.parse(decryptWithPrivateKey(res.data.sensitiveData)) as Record<string, unknown>;
}

// ----------------------------- callable ------------------------------------

export interface NagadCreatePaymentInput {
  orderId: string;
}

export const nagadCreatePayment = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const authCtx = assertAuth(req);
    const uid = authCtx.uid;
    const input = (req.data ?? {}) as Partial<NagadCreatePaymentInput>;
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

    const invoiceId = `PB-${orderId.slice(0, 12)}`;
    const init = await initiate({ amountPoisha, invoiceId, userId: uid });

    const paymentRef = db.collection("payments").doc(init.paymentRefId);
    await paymentRef.set({
      id: init.paymentRefId,
      provider: "nagad",
      orderId,
      customerUid: uid,
      amountPoisha,
      invoiceId,
      status: "initiated",
      gatewayRef: init.paymentRefId,
      gatewayUrl: init.callBackUrl,
      createdAt: Date.now(),
    });

    await recordAudit({
      actorUid: uid,
      action: "payment.initiated",
      targetType: "payment",
      targetId: init.paymentRefId,
      after: { provider: "nagad", orderId, amountPoisha },
    });

    const out: CreatePaymentResult = {
      provider: "nagad",
      gatewayUrl: init.callBackUrl,
      paymentRefId: init.paymentRefId,
      orderId,
      amountPoisha,
    };
    return out;
  },
);
