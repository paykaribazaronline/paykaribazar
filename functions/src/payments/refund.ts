/**
 * Admin-only: `refundPayment`.
 *
 * Supports full and partial refunds. Calls the provider's refund API (bKash /
 * Nagad / SSLCommerz). For bank transfers it only marks the payment as
 * "refund_pending_bank" and writes a refund request, since bank refunds must
 * be done manually by the accounts team.
 *
 * On success:
 *   - Appends to `payments/{paymentId}.refunds[]` with provider refundId,
 *     amount, reason, timestamp.
 *   - Updates `orders/{orderId}.paymentStatus` to:
 *       * 'refunded'                (full refund)
 *       * 'partially_refunded'      (partial refund)
 *
 * Refunds are idempotent: re-calling with the same `requestId` returns the
 * existing refund record instead of issuing a second one.
 */
import { onCall } from "firebase-functions/v2/https";
import {
  db,
  assertAdmin,
  FieldValue,
} from "../admin";
import {
  errInvalidArgument,
  errFailedPrecondition,
  errNotFound,
  poishaToTaka,
  takaToPoisha,
} from "../shared/security";
import { recordAudit } from "../audit/auditLog";
import { grantToken as bkashGrantToken, BKASH_BASE_URL } from "./bkash";
import { httpClient, sanitise } from "./_http";

type Provider = "bkash" | "nagad" | "sslcommerz" | "bank_transfer";

export interface RefundPaymentInput {
  paymentId: string;
  amount?: number; // in taka; defaults to full refund
  reason: string;
  requestId: string; // client-supplied idempotency key (UUID)
}

export interface RefundRecord {
  refundId: string;
  amountPoisha: number;
  reason: string;
  providerRefundRef: string | null;
  status: "initiated" | "completed" | "failed";
  at: number;
}

export const refundPayment = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const caller = assertAdmin(req);
    const input = (req.data ?? {}) as Partial<RefundPaymentInput>;
    const paymentId = (input.paymentId ?? "").toString().trim();
    const reason = (input.reason ?? "").toString().trim();
    const requestId = (input.requestId ?? "").toString().trim();
    const amount = input.amount; // taka

    if (!paymentId) errInvalidArgument("paymentId is required.");
    if (!reason || reason.length < 3) {
      errInvalidArgument("A reason (>= 3 chars) is required.");
    }
    if (!requestId) errInvalidArgument("requestId (idempotency key) is required.");

    const paymentRef = db.doc(`payments/${paymentId}`);
    const pSnap = await paymentRef.get();
    if (!pSnap.exists) errNotFound(`Payment ${paymentId} not found.`);
    const payment = pSnap.data() as Record<string, unknown>;
    if (payment.status !== "verified" && payment.status !== "paid") {
      errFailedPrecondition(
        `Cannot refund a payment with status ${payment.status}.`,
      );
    }

    // ----- Idempotency check -----
    const existingRefunds = (payment.refunds ?? []) as RefundRecord[];
    const existing = existingRefunds.find((r) => r.refundId === requestId);
    if (existing) {
      return { refund: existing, idempotent: true };
    }

    const totalPaidPoisha = Number(payment.amountPaidPoisha ?? payment.amountPoisha ?? 0);
    const refundAmountPoisha =
      typeof amount === "number" ? takaToPoisha(amount) : totalPaidPoisha;
    if (refundAmountPoisha <= 0 || refundAmountPoisha > totalPaidPoisha) {
      errInvalidArgument(
        `Refund amount must be between 0.01 and ${poishaToTaka(totalPaidPoisha)} BDT.`,
      );
    }
    const isFullRefund = refundAmountPoisha === totalPaidPoisha;

    const provider = String(payment.provider ?? "") as Provider;
    let providerRefundRef: string | null = null;
    let refundStatus: RefundRecord["status"] = "initiated";

    try {
      if (provider === "bkash") {
        const token = await bkashGrantToken();
        const paymentID = String(payment.gatewayRef ?? payment.id);
        const res = await httpClient({
          baseURL: BKASH_BASE_URL,
          headers: { Authorization: token },
        }).post("/payment/refund", {
          paymentID,
          amount: poishaToTaka(refundAmountPoisha).toFixed(2),
          currency: "BDT",
          trxID: payment.gatewayRef,
          sku: "order",
          reason,
        });
        if (res.data?.statusCode === "0000") {
          providerRefundRef = String(res.data?.refundTrxID ?? null);
          refundStatus = "completed";
        } else {
          refundStatus = "failed";
        }
      } else if (provider === "nagad" || provider === "sslcommerz") {
        // Nagad / SSLCommerz refunds require out-of-band merchant console
        // action. We mark it as `initiated` and emit a refund request doc so
        // the accounts team can complete it.
        await db.collection("refundRequests").doc().set({
          paymentId,
          provider,
          amountPoisha: refundAmountPoisha,
          reason,
          requestedBy: caller.uid,
          status: "pending_external_action",
          createdAt: FieldValue.serverTimestamp(),
        });
        refundStatus = "initiated";
      } else if (provider === "bank_transfer") {
        // Bank refunds are always manual.
        await db.collection("refundRequests").doc().set({
          paymentId,
          provider: "bank_transfer",
          amountPoisha: refundAmountPoisha,
          reason,
          requestedBy: caller.uid,
          status: "pending_external_action",
          createdAt: FieldValue.serverTimestamp(),
        });
        refundStatus = "initiated";
      } else {
        errFailedPrecondition(`Refunds not supported for provider ${provider}.`);
      }
    } catch (err) {
      // Axios errors carry the full request config (incl. `Authorization`
      // header) and the gateway response body (which may include `trxID`,
      // `refundTrxID`, masked card numbers). Sanitise before logging.
      console.error("[refundPayment] provider call failed:", sanitise(err));
      refundStatus = "failed";
    }

    const refund: RefundRecord = {
      refundId: requestId,
      amountPoisha: refundAmountPoisha,
      reason,
      providerRefundRef,
      status: refundStatus,
      at: Date.now(),
    };

    const newPaymentStatus = isFullRefund ? "refunded" : "partially_refunded";
    const newOrderStatus = isFullRefund ? "cancelled" : "confirmed";

    await db.runTransaction(async (tx) => {
      const oRef = db.doc(`orders/${String(payment.orderId ?? "")}`);
      tx.set(
        paymentRef,
        {
          refunds: FieldValue.arrayUnion(refund),
          refundStatus: refund.status,
          status:
            refund.status === "completed" && isFullRefund
              ? "refunded"
              : refund.status === "completed"
                ? "partially_refunded"
                : payment.status,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      tx.set(
        oRef,
        {
          paymentStatus: refund.status === "completed" ? newPaymentStatus : "unpaid",
          status: refund.status === "completed" ? newOrderStatus : undefined,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    });

    await recordAudit({
      actorUid: caller.uid,
      action: "payment.refund_issued",
      targetType: "payment",
      targetId: paymentId,
      after: refund,
      metadata: { provider, isFullRefund },
    });

    return { refund, idempotent: false };
  },
);
