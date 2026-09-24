/**
 * Callable `releaseReservation`.
 *
 * Used by:
 *   - The Flutter client when the user abandons checkout (so we don't keep
 *     stock locked for 15 minutes).
 *   - A payment failure webhook.
 *   - A scheduled sweep for expired reservations (cron can call this with a
 *     service-account UID).
 *
 * Owner of the reservation OR staff/admin may call it. The transaction is
 * idempotent — if the reservation is already `released` or `committed`, we
 * no-op. `committed` reservations are NEVER released here — they must be
 * refunded via `refundPayment` instead.
 */
import { onCall } from "firebase-functions/v2/https";
import {
  db,
  assertAuth,
  FieldValue,
  Timestamp,
  isOwnerOrAdmin,
} from "../admin";
import { errInvalidArgument, errNotFound, errFailedPrecondition } from "../shared/security";
import { recordAudit } from "../audit/auditLog";

export interface ReleaseReservationInput {
  reservationId: string;
  reason?: string;
}

export const releaseReservation = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const authCtx = assertAuth(req);
    const uid = authCtx.uid;
    const input = (req.data ?? {}) as Partial<ReleaseReservationInput>;
    const reservationId = (input.reservationId ?? "").toString().trim();
    const reason = (input.reason ?? "user_cancelled").toString().trim();
    if (!reservationId) {
      errInvalidArgument("reservationId is required.");
    }

    const reservationRef = db.doc(`inventoryReservations/${reservationId}`);

    const result = await db.runTransaction(async (tx) => {
      const snap = await tx.get(reservationRef);
      if (!snap.exists) errNotFound(`Reservation ${reservationId} not found.`);
      const r = snap.data() as Record<string, unknown>;
      const status = String(r.status ?? "");
      const ownerId = String(r.userId ?? "");

      // Owner or staff/admin only.
      if (!isOwnerOrAdmin(req, ownerId) && uid !== ownerId) {
        errFailedPrecondition("You may only release your own reservations.");
      }

      if (status === "released" || status === "expired") {
        return { status: status as "released" | "expired" };
      }
      if (status === "committed") {
        errFailedPrecondition(
          "Reservation already committed — use refundPayment to undo a paid order.",
        );
      }

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
        reservationRef,
        {
          status: "released",
          releasedAt: Timestamp.now(),
          releasedBy: uid,
          releaseReason: reason,
        },
        { merge: true },
      );
      return { status: "released" as const };
    });

    await recordAudit({
      actorUid: uid,
      action: "reservation.released",
      targetType: "reservation",
      targetId: reservationId,
      after: result,
      metadata: { reason },
    });

    return { reservationId, ...result };
  },
);
