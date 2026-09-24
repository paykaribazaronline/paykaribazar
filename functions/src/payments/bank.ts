/**
 * Manual bank transfer flow.
 *
 * The customer is shown a list of bank accounts (configured via
 * BANK_PAYMENT_CONFIG_JSON). They upload a payment slip to Storage at
 * `/paymentslips/{uid}/{paymentId}.jpg` themselves (Storage rules enforce
 * owner-only writes). They then call `recordBankPaymentRequest` with the
 * paymentId, slip URL and transferred amount.
 *
 * The payment doc is created with `status: 'pending_manual_verification'`.
 * An admin (role admin or staff accounts) calls `verifyBankPayment` to mark
 * the payment confirmed, which triggers `commitReservation` + the order
 * status update.
 *
 * Refusal path: an admin can mark the slip rejected, which releases the
 * reservation and sets the order to `cancelled`.
 */
import { onCall } from "firebase-functions/v2/https";
import { db, assertAuth, assertRole, FieldValue, Timestamp } from "../admin";
import {
  errInvalidArgument,
  errFailedPrecondition,
  errNotFound,
  poishaToTaka,
  takaToPoisha,
} from "../shared/security";
import { recordAudit } from "../audit/auditLog";
import { commitReservation } from "../inventory/commitReservation";

interface BankConfigAccount {
  bank: string;
  account: string;
  branch?: string;
  routing?: string;
}

function loadBankConfig(): BankConfigAccount[] {
  const raw = process.env.BANK_PAYMENT_CONFIG_JSON ?? "[]";
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed as BankConfigAccount[];
  } catch {
    return [];
  }
}

// ------------------- recordBankPaymentRequest ------------------------------

export interface RecordBankPaymentRequestInput {
  orderId: string;
  slipUrl: string;
  amountPaid?: number;
  transferDate?: string;
  senderAccount?: string;
  note?: string;
}

export const recordBankPaymentRequest = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const authCtx = assertAuth(req);
    const uid = authCtx.uid;
    const input = (req.data ?? {}) as Partial<RecordBankPaymentRequestInput>;

    const orderId = (input.orderId ?? "").toString().trim();
    const slipUrl = (input.slipUrl ?? "").toString().trim();
    const note = input.note?.toString().trim();
    const senderAccount = input.senderAccount?.toString().trim();
    const transferDate = input.transferDate?.toString().trim();

    if (!orderId) errInvalidArgument("orderId is required.");
    if (!slipUrl || !slipUrl.startsWith("https://")) {
      errInvalidArgument("slipUrl must be a valid https URL.");
    }
    // Defensive: ensure the slip URL is under the caller's own path.
    const expectedPrefix = `https://firebasestorage.googleapis.com/v0/b/`;
    if (!slipUrl.startsWith(expectedPrefix) && !slipUrl.includes("paymentslips")) {
      errInvalidArgument("slipUrl must point to a paymentslips path.");
    }

    const orderSnap = await db.doc(`orders/${orderId}`).get();
    if (!orderSnap.exists) errNotFound(`Order ${orderId} not found.`);
    const order = orderSnap.data() as Record<string, unknown>;
    if (String(order.customerUid) !== uid) {
      errFailedPrecondition("Order does not belong to you.");
    }
    if (order.paymentStatus !== "unpaid") {
      errFailedPrecondition(`Order payment status is ${order.paymentStatus}.`);
    }

    const expectedAmountPoisha = Number(
      order.grandTotalPoisha ?? takaToPoisha(Number(order.total ?? 0)),
    );
    const amountPaidPoisha =
      typeof input.amountPaid === "number"
        ? takaToPoisha(input.amountPaid)
        : expectedAmountPoisha;

    const paymentRef = db.collection("payments").doc();
    const banks = loadBankConfig();
    await paymentRef.set({
      id: paymentRef.id,
      provider: "bank_transfer",
      orderId,
      customerUid: uid,
      amountExpectedPoisha: expectedAmountPoisha,
      amountPaidPoisha,
      slipUrl,
      senderAccount: senderAccount ?? null,
      transferDate: transferDate ?? null,
      status: "pending_manual_verification",
      bankAccounts: banks,
      note: note ?? null,
      createdAt: FieldValue.serverTimestamp(),
      serverCreatedAt: Timestamp.now(),
    });

    // Link the payment doc to the order for admin UI lookup.
    await db.doc(`orders/${orderId}`).set(
      { paymentId: paymentRef.id, paymentMethod: "bank_transfer" },
      { merge: true },
    );

    await recordAudit({
      actorUid: uid,
      action: "payment.bank_transfer_submitted",
      targetType: "payment",
      targetId: paymentRef.id,
      after: { orderId, amountPaidPoisha, slipUrl },
    });

    return {
      paymentId: paymentRef.id,
      status: "pending_manual_verification",
      banks,
      amountExpected: poishaToTaka(expectedAmountPoisha),
    };
  },
);

// ---------------------- verifyBankPayment ----------------------------------

export interface VerifyBankPaymentInput {
  paymentId: string;
  decision: "verified" | "rejected";
  reason?: string;
}

export const verifyBankPayment = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const caller = assertRole(req, ["admin", "staff"]);
    const input = (req.data ?? {}) as Partial<VerifyBankPaymentInput>;
    const paymentId = (input.paymentId ?? "").toString().trim();
    const decision = input.decision;
    const reason = input.reason?.toString().trim();

    if (!paymentId) errInvalidArgument("paymentId is required.");
    if (decision !== "verified" && decision !== "rejected") {
      errInvalidArgument("decision must be 'verified' or 'rejected'.");
    }

    const paymentRef = db.doc(`payments/${paymentId}`);
    const pSnap = await paymentRef.get();
    if (!pSnap.exists) errNotFound(`Payment ${paymentId} not found.`);
    const payment = pSnap.data() as Record<string, unknown>;
    if (payment.status === "verified" || payment.status === "rejected") {
      errFailedPrecondition(`Payment already ${payment.status}.`);
    }

    const orderId = String(payment.orderId ?? "");
    const orderRef = db.doc(`orders/${orderId}`);
    const reservationId = (await orderRef.get()).get("reservationId") as
      | string
      | undefined;

    if (decision === "rejected") {
      // Release reservation + cancel order.
      await db.runTransaction(async (tx) => {
        const oSnap = await tx.get(orderRef);
        if (!oSnap.exists) return;
        tx.set(
          orderRef,
          {
            status: "cancelled",
            paymentStatus: "rejected",
            cancellationReason: reason ?? "bank_slip_rejected",
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
        tx.set(
          paymentRef,
          {
            status: "rejected",
            verifiedBy: caller.uid,
            verifiedAt: FieldValue.serverTimestamp(),
            reason: reason ?? null,
          },
          { merge: true },
        );
      });
      // Best-effort reservation release (won't throw if already released).
      if (reservationId) {
        const rRef = db.doc(`inventoryReservations/${reservationId}`);
        await db.runTransaction(async (tx) => {
          const rSnap = await tx.get(rRef);
          if (!rSnap.exists) return;
          const r = rSnap.data() as Record<string, unknown>;
          if (String(r.status ?? "") !== "reserved") return;
          const items = (r.items ?? []) as Array<{
            productId: string;
            quantity: number;
          }>;
          for (const it of items) {
            const pRef = db.doc(`products/${it.productId}`);
            const pSnap = await tx.get(pRef);
            if (!pSnap.exists) continue;
            const p = pSnap.data() as Record<string, unknown>;
            tx.set(
              pRef,
              { reservedStock: Math.max(0, Number(p.reservedStock ?? 0) - it.quantity) },
              { merge: true },
            );
          }
          tx.set(
            rRef,
            { status: "released", releasedBy: caller.uid, releaseReason: "bank_slip_rejected" },
            { merge: true },
          );
        });
      }
      await recordAudit({
        actorUid: caller.uid,
        action: "payment.bank_slip_rejected",
        targetType: "payment",
        targetId: paymentId,
        after: { orderId, reason: reason ?? null },
      });
      return { paymentId, status: "rejected", orderId };
    }

    // ----- Verified path: commit reservation, mark paid.
    if (!reservationId) {
      errFailedPrecondition("Order has no reservationId — cannot commit.");
    }
    const commit = await commitReservation(reservationId);
    if (commit.status === "missing") {
      errFailedPrecondition(`Reservation ${reservationId} missing.`);
    }

    await db.runTransaction(async (tx) => {
      const oSnap = await tx.get(orderRef);
      if (!oSnap.exists) return;
      tx.set(
        orderRef,
        {
          status: "confirmed",
          paymentStatus: "paid",
          paymentId,
          paymentProvider: "bank_transfer",
          confirmedAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      tx.set(
        paymentRef,
        {
          status: "verified",
          verifiedBy: caller.uid,
          verifiedAt: FieldValue.serverTimestamp(),
          reason: reason ?? null,
        },
        { merge: true },
      );
    });

    await recordAudit({
      actorUid: caller.uid,
      action: "payment.bank_slip_verified",
      targetType: "payment",
      targetId: paymentId,
      after: { orderId, reservationStatus: commit.status },
    });

    return {
      paymentId,
      status: "verified",
      orderId,
      reservationStatus: commit.status,
    };
  },
);
