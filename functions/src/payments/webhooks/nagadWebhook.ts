/**
 * HTTPS webhook: Nagad.
 *
 * Nagad POSTs `payment_ref_id`, `merchant_invoice_number`, `status` and an
 * HMAC `signature` field over the JSON body. We verify, then re-call
 * `verify(paymentRefId, orderId, amountPoisha)` to be sure the payment is
 * genuine (defence in depth: don't trust the redirect body).
 *
 * Idempotency via `payments/{paymentRefId}.status`.
 */
import { onRequest } from "firebase-functions/v2/https";
import { db } from "../../admin";
import { verify } from "../nagad";
import { markPaymentPaid, verifyHmac } from "./_shared";

export const nagadWebhook = onRequest(
  { region: "asia-southeast1", maxInstances: 50 },
  async (req, res) => {
    const rawBody =
      typeof req.rawBody === "string"
        ? Buffer.from(req.rawBody)
        : (req.rawBody ?? Buffer.from(JSON.stringify(req.body)));

    const signatureHeader =
      (req.headers["x-nagad-signature"] as string | undefined) ??
      (req.headers["x-signature"] as string | undefined);

    if (!verifyHmac(rawBody, signatureHeader)) {
      res.status(401).send("invalid signature");
      return;
    }

    const payload = req.body as Record<string, unknown>;
    const paymentRefId = String(payload?.payment_ref_id ?? "");
    const merchantOrderId = String(payload?.merchant_invoice_number ?? "");
    const status = String(payload?.status ?? "");

    if (!paymentRefId || !merchantOrderId) {
      res.status(400).send("missing payment_ref_id or merchant_invoice_number");
      return;
    }

    const paymentsSnap = await db
      .collection("payments")
      .where("gatewayRef", "==", paymentRefId)
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

    // Re-verify server-side regardless of webhook status.
    const verified = await verify(paymentRefId, merchantOrderId, amountPoisha).catch(
      (err) => {
        console.error("[nagadWebhook] verify failed:", err);
        return null;
      },
    );

    if (!verified || String(verified.status ?? "").toLowerCase() !== "success") {
      await db
        .collection("webhookEvents")
        .doc(`nagad-${paymentRefId}-${Date.now()}`)
        .set({
          provider: "nagad",
          paymentRefId,
          merchantOrderId,
          webhookStatus: status,
          verifiedPayload: verified,
          receivedAt: Date.now(),
        });
      res.status(200).send("pending");
      return;
    }

    const result = await markPaymentPaid({
      paymentId: paymentDoc.id,
      provider: "nagad",
      gatewayRef: paymentRefId,
      gatewayPayload: verified,
      orderId,
      amountPoisha,
    });

    res.status(200).json({ ok: true, committed: result.committed });
  },
);
