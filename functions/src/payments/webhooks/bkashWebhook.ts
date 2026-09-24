/**
 * HTTPS webhook: bKash.
 *
 * Public (no auth) — bKash POSTs here on payment completion. We verify an
 * HMAC signature over the raw body, then re-fetch the payment via
 * `searchPayment(paymentID)` so we don't trust the webhook payload alone.
 *
 * Idempotency: the `payments/{paymentId}` doc is checked first; if it is
 * already `verified`, we return 200 immediately.
 */
import { onRequest } from "firebase-functions/v2/https";
import { db } from "../../admin";
import { searchPayment } from "../bkash";
import { markPaymentPaid, verifyHmac } from "./_shared";

export const bkashWebhook = onRequest(
  {
    region: "asia-southeast1",
    maxInstances: 50,
  },
  async (req, res) => {
    const rawBody =
      typeof req.rawBody === "string"
        ? Buffer.from(req.rawBody)
        : (req.rawBody ?? Buffer.from(JSON.stringify(req.body)));

    const signatureHeader = (req.headers["x-bkash-signature"] as string | undefined) ??
      (req.headers["x-signature"] as string | undefined);

    if (!verifyHmac(rawBody, signatureHeader)) {
      res.status(401).send("invalid signature");
      return;
    }

    const payload = req.body as Record<string, unknown>;
    const paymentID = String(payload?.paymentID ?? "");
    if (!paymentID) {
      res.status(400).send("missing paymentID");
      return;
    }

    // Re-verify with the gateway so we never accept a spoofed webhook.
    const gateway = await searchPayment(paymentID).catch((err) => {
      console.error("[bkashWebhook] searchPayment failed:", err);
      return null;
    });
    if (!gateway || gateway.transactionStatus !== "Completed") {
      // Persist the pending event so we can retry later — but return 200 so
      // bKash doesn't keep hammering us.
      await db
        .collection("webhookEvents")
        .doc(`bkash-${paymentID}-${Date.now()}`)
        .set({
          provider: "bkash",
          paymentID,
          payload,
          gateway: gateway ?? null,
          status: "pending",
          receivedAt: Date.now(),
        });
      res.status(200).send("pending");
      return;
    }

    // Look up our internal payment doc by gatewayRef.
    const paymentsSnap = await db
      .collection("payments")
      .where("gatewayRef", "==", paymentID)
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

    const result = await markPaymentPaid({
      paymentId: paymentDoc.id,
      provider: "bkash",
      gatewayRef: paymentID,
      gatewayPayload: gateway,
      orderId,
      amountPoisha,
    });

    res.status(200).json({ ok: true, committed: result.committed });
  },
);
