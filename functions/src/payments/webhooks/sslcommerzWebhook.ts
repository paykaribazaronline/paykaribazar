/**
 * HTTPS webhook: SSLCommerz.
 *
 * SSLCommerz sends `val_id`, `tran_id`, `status`, `amount`, `currency_amount`
 * etc. on success / IPN. We DO NOT trust the body alone: we call
 * `validate(val_id)` to confirm the payment with SSLCommerz directly. Only
 * then do we mark the order paid.
 *
 * Idempotency via `payments/{tran_id}.status`.
 */
import { onRequest } from "firebase-functions/v2/https";
import { db } from "../../admin";
import { validate } from "../sslcommerz";
import { markPaymentPaid, verifyHmac } from "./_shared";

export const sslcommerzWebhook = onRequest(
  { region: "asia-southeast1", maxInstances: 50 },
  async (req, res) => {
    const rawBody =
      typeof req.rawBody === "string"
        ? Buffer.from(req.rawBody)
        : (req.rawBody ?? Buffer.from(JSON.stringify(req.body)));

    const signatureHeader =
      (req.headers["x-sslcommerz-signature"] as string | undefined) ??
      (req.headers["x-signature"] as string | undefined) ??
      (req.headers["verify_key"] as string | undefined); // SSLCommerz uses verify_key/sign

    if (!verifyHmac(rawBody, signatureHeader)) {
      res.status(401).send("invalid signature");
      return;
    }

    const payload = (req.body ?? {}) as Record<string, unknown>;
    const tranId = String(payload.tran_id ?? "");
    const valId = String(payload.val_id ?? "");
    const status = String(payload.status ?? "");

    if (!tranId) {
      res.status(400).send("missing tran_id");
      return;
    }

    const paymentsSnap = await db
      .collection("payments")
      .where("gatewayRef", "==", tranId)
      .limit(1)
      .get();
    if (paymentsSnap.empty) {
      res.status(404).send("payment not found");
      return;
    }
    const paymentDoc = paymentsSnap.docs[0];
    if (!paymentDoc) {
      res.status(404).send("payment not found");
      return;
    }
    const paymentData = paymentDoc.data();
    const orderId = String(paymentData.orderId ?? "");
    const amountPoisha = Number(paymentData.amountPoisha ?? 0);

    // Always re-validate server-side.
    const validated = valId
      ? await validate(valId).catch((err) => {
          console.error("[sslcommerzWebhook] validate failed:", err);
          return null;
        })
      : null;

    if (!validated || validated.status !== "VALID") {
      await db
        .collection("webhookEvents")
        .doc(`sslcz-${tranId}-${Date.now()}`)
        .set({
          provider: "sslcommerz",
          tranId,
          valId,
          webhookStatus: status,
          validatedPayload: validated,
          receivedAt: Date.now(),
        });
      res.status(200).send("pending");
      return;
    }

    const result = await markPaymentPaid({
      paymentId: paymentDoc.id,
      provider: "sslcommerz",
      gatewayRef: tranId,
      gatewayPayload: validated,
      orderId,
      amountPoisha,
    });

    res.status(200).json({ ok: true, committed: result.committed });
  },
);
