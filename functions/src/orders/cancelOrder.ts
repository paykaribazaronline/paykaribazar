/**
 * Callable `cancelOrder`.
 *
 * Allowed when:
 *   - caller is the order's owner OR staff/admin.
 *   - order.status is `pending_payment` or `confirmed` (i.e. not shipped /
 *     delivered / already cancelled).
 *
 * Behaviour:
 *   - If order is unpaid (`paymentStatus === 'unpaid'`): releases the
 *     associated reservation atomically and sets order.status='cancelled'.
 *   - If order is paid (`paymentStatus === 'paid'`): sets status to
 *     'cancellation_requested' and creates a refund request doc so the admin
 *     can complete the refund via `refundPayment`. Does NOT auto-refund.
 *
 * `reason` is required and is persisted both on the order and in the audit log.
 */
import { onCall } from "firebase-functions/v2/https";
import {
  db,
  assertAuth,
  FieldValue,
  Timestamp,
} from "../admin";
import {
  errInvalidArgument,
  errFailedPrecondition,
  errNotFound,
} from "../shared/security";
import { recordAudit } from "../audit/auditLog";

export interface CancelOrderInput {
  orderId: string;
  reason: string;
}

export const cancelOrder = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const authCtx = assertAuth(req);
    const uid = authCtx.uid;
    const input = (req.data ?? {}) as Partial<CancelOrderInput>;
    const orderId = (input.orderId ?? "").toString().trim();
    const reason = (input.reason ?? "").toString().trim();

    if (!orderId) errInvalidArgument("orderId is required.");
    if (!reason || reason.length < 3) {
      errInvalidArgument("A reason (>= 3 chars) is required.");
    }

    const orderRef = db.doc(`orders/${orderId}`);

    const result = await db.runTransaction(async (tx) => {
      const oSnap = await tx.get(orderRef);
      if (!oSnap.exists) errNotFound(`Order ${orderId} not found.`);
      const order = oSnap.data() as Record<string, unknown>;
      const ownerUid = String(order.customerUid ?? "");

      // Authorization: caller is owner OR staff/admin (asserted by role
      // check on the request — but Firestore doesn't know claims, so we
      // re-check here using a custom-claim read on `req.auth`).
      const callerRole = (req.auth?.token as Record<string, unknown> | undefined)?.role;
      const isAdmin = callerRole === "admin";
      const isStaff = callerRole === "staff";
      if (ownerUid !== uid && !isAdmin && !isStaff) {
        errFailedPrecondition("You can only cancel your own orders.");
      }

      const status = String(order.status ?? "");
      if (
        status === "cancelled" ||
        status === "delivered" ||
        status === "shipped"
      ) {
        errFailedPrecondition(
          `Order is '${status}' and cannot be cancelled.`,
        );
      }

      const paymentStatus = String(order.paymentStatus ?? "unpaid");
      const reservationId = (order.reservationId as string | null) ?? null;

      if (paymentStatus === "unpaid") {
        // Release the reservation if it's still reserved.
        if (reservationId) {
          const rRef = db.doc(`inventoryReservations/${reservationId}`);
          const rSnap = await tx.get(rRef);
          if (rSnap.exists) {
            const r = rSnap.data() as Record<string, unknown>;
            if (String(r.status ?? "") === "reserved") {
              const items = (r.items ?? []) as Array<{
                productId: string;
                quantity: number;
              }>;
              for (const it of items) {
                const pRef = db.doc(`products/${it.productId}`);
                const pSnap = await tx.get(pRef);
                if (!pSnap.exists) continue;
                const p = pSnap.data() as Record<string, unknown>;
                const reserved = Number(p.reservedStock ?? 0);
                tx.set(
                  pRef,
                  {
                    reservedStock: Math.max(0, reserved - it.quantity),
                    updatedAt: FieldValue.serverTimestamp(),
                  },
                  { merge: true },
                );
              }
              tx.set(
                rRef,
                {
                  status: "released",
                  releasedAt: Timestamp.now(),
                  releasedBy: uid,
                  releaseReason: `order_cancelled:${orderId}`,
                },
                { merge: true },
              );
            }
          }
        }

        tx.set(
          orderRef,
          {
            status: "cancelled",
            cancellationReason: reason,
            cancelledAt: FieldValue.serverTimestamp(),
            cancelledBy: uid,
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
        return { finalStatus: "cancelled", paymentStatus } as const;
      }

      // Paid order — don't auto-refund; ask for admin review.
      tx.set(
        orderRef,
        {
          status: "cancellation_requested",
          cancellationReason: reason,
          cancellationRequestedAt: FieldValue.serverTimestamp(),
          cancellationRequestedBy: uid,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

      const refundRef = db.collection("refundRequests").doc();
      tx.set(refundRef, {
        id: refundRef.id,
        orderId,
        customerUid: ownerUid,
        requestedBy: uid,
        amountPoisha: Number(order.grandTotalPoisha ?? 0),
        reason,
        status: "pending_review",
        createdAt: FieldValue.serverTimestamp(),
      });
      return { finalStatus: "cancellation_requested", paymentStatus } as const;
    });

    await recordAudit({
      actorUid: uid,
      action: "order.cancel_requested",
      targetType: "order",
      targetId: orderId,
      after: result,
      metadata: { reason },
    });

    return { orderId, ...result };
  },
);
