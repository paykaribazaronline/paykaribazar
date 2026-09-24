/**
 * Callable `verifyPayment` — used when the Flutter client polls after a
 * redirect. We re-query the provider and mark paid if verified. Idempotent.
 *
 * The Flutter client should call this every ~3 seconds for ~2 minutes after
 * returning from the gateway. If a webhook already marked the order paid, the
 * call is a cheap no-op.
 */
import { onCall } from "firebase-functions/v2/https";
import { db, assertAuth } from "../admin";
import {
  errInvalidArgument,
  errFailedPrecondition,
  errNotFound,
} from "../shared/security";
import { recordAudit } from "../audit/auditLog";
import { markPaymentPaid } from "./webhooks/_shared";
import { searchPayment as bkashSearch } from "./bkash";
import { verify as nagadVerify } from "./nagad";
import { sanitise } from "./_http";
// NOTE: SSLCommerz's `validate()` is intentionally NOT imported here. The
// `verifyPayment` callable relies on the SSLCommerz webhook (sslcommerzWebhook)
// to commit payments — there's no client-pollable "search by sessionkey"
// endpoint. The sslcommerz case below is a no-op that tells the client to
// keep polling. Removing the unused import silences eslint without changing
// runtime behaviour.

type Provider = "bkash" | "nagad" | "sslcommerz";

export interface VerifyPaymentInput {
  provider: Provider;
  paymentRefId: string;
  orderId: string;
}

export const verifyPayment = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const authCtx = assertAuth(req);
    const uid = authCtx.uid;
    const input = (req.data ?? {}) as Partial<VerifyPaymentInput>;
    const provider = input.provider as Provider | undefined;
    const paymentRefId = (input.paymentRefId ?? "").toString().trim();
    const orderId = (input.orderId ?? "").toString().trim();

    if (!provider || !["bkash", "nagad", "sslcommerz"].includes(provider)) {
      errInvalidArgument("provider must be bkash, nagad, or sslcommerz.");
    }
    if (!paymentRefId || !orderId) {
      errInvalidArgument("paymentRefId and orderId are required.");
    }

    const orderSnap = await db.doc(`orders/${orderId}`).get();
    if (!orderSnap.exists) errNotFound(`Order ${orderId} not found.`);
    const order = orderSnap.data() as Record<string, unknown>;
    if (String(order.customerUid) !== uid) {
      errFailedPrecondition("Order does not belong to you.");
    }
    if (order.paymentStatus === "paid") {
      return { orderId, paymentStatus: "paid", alreadyVerified: true };
    }

    const paymentsSnap = await db
      .collection("payments")
      .where("gatewayRef", "==", paymentRefId)
      .limit(1)
      .get();
    if (paymentsSnap.empty) errNotFound("Payment record not found.");
    const paymentDoc = paymentsSnap.docs[0];
    if (!paymentDoc) errNotFound("Payment record not found.");
    const paymentData = paymentDoc.data();
    const amountPoisha = Number(paymentData.amountPoisha ?? 0);

    let verifiedPayload: Record<string, unknown> | null = null;

    if (provider === "bkash") {
      const r = await bkashSearch(paymentRefId).catch((e) => {
        console.error("[verifyPayment] bkash search failed:", sanitise(e));
        return null;
      });
      if (r && r.transactionStatus === "Completed") verifiedPayload = r;
    } else if (provider === "nagad") {
      const invoiceId = String(paymentData.invoiceId ?? "");
      const r = await nagadVerify(paymentRefId, invoiceId, amountPoisha).catch(
        (e) => {
          console.error("[verifyPayment] nagad verify failed:", sanitise(e));
          return null;
        },
      );
      if (r && String(r.status ?? "").toLowerCase() === "success") verifiedPayload = r;
    } else {
      // sslcommerz — paymentRefId is our tran_id; we don't have val_id here,
      // so we use the stored sessionkey to look up validation.
      const sessionkey = String(paymentData.sessionkey ?? "");
      if (!sessionkey) {
        errFailedPrecondition("SSLCommerz sessionkey missing on payment record.");
      }
      // SSLCommerz has no 'search by sessionkey' endpoint; rely on webhook
      // for the actual commit. We just no-op here and tell the client to
      // keep polling.
      return {
        orderId,
        paymentStatus: "unpaid",
        alreadyVerified: false,
        message: "sslcommerz commits via webhook; please wait a moment.",
      };
    }

    if (!verifiedPayload) {
      return { orderId, paymentStatus: "unpaid", alreadyVerified: false };
    }

    const result = await markPaymentPaid({
      paymentId: paymentDoc.id,
      provider,
      gatewayRef: paymentRefId,
      gatewayPayload: verifiedPayload,
      orderId,
      amountPoisha,
    });

    await recordAudit({
      actorUid: uid,
      action: "payment.client_verified",
      targetType: "payment",
      targetId: paymentDoc.id,
      after: result,
    });

    return {
      orderId,
      paymentStatus: "paid",
      alreadyVerified: !result.committed,
    };
  },
);
