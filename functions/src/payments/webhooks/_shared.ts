/**
 * Shared webhook helpers: HMAC signature verification + idempotent payment
 * commit + sanitised persistence.
 */
import * as crypto from "crypto";
import { https } from "firebase-functions";
import { db, FieldValue, Timestamp } from "../../admin";
import { recordAudit } from "../../audit/auditLog";
import { sanitise } from "../_http";
import { commitReservation, type CommitResult } from "../../inventory/commitReservation";

const HMAC_SECRET = process.env.WEBHOOK_HMAC_SECRET ?? "";

/** Verify an HMAC-SHA256 signature sent in a header over the raw body. */
export function verifyHmac(rawBody: Buffer, signatureHeader: string | undefined): boolean {
  if (!HMAC_SECRET) {
    throw new https.HttpsError(
      "failed-precondition",
      "Server missing WEBHOOK_HMAC_SECRET.",
    );
  }
  if (!signatureHeader) return false;
  const sig = signatureHeader.startsWith("sha256=")
    ? signatureHeader.slice(7)
    : signatureHeader;
  const expected = crypto
    .createHmac("sha256", HMAC_SECRET)
    .update(rawBody)
    .digest("hex");
  const a = Buffer.from(expected);
  const b = Buffer.from(sig);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

/** Idempotent payment success commit. Returns whether THIS call did the work. */
export async function markPaymentPaid(args: {
  paymentId: string;
  provider: "bkash" | "nagad" | "sslcommerz";
  gatewayRef: string;
  gatewayPayload: Record<string, unknown>;
  orderId: string;
  amountPoisha: number;
}): Promise<{ committed: boolean; reservationStatus: CommitResult["status"] }> {
  const paymentRef = db.doc(`payments/${args.paymentId}`);
  const orderRef = db.doc(`orders/${args.orderId}`);

  // Fast-path idempotency pre-check (cheap read outside the transaction so the
  // common "gateway re-delivered the same webhook" case doesn't pay the cost
  // of `commitReservation` + a transaction). This is BEST-EFFORT only — the
  // authoritative check is inside the transaction below (a concurrent pair of
  // webhook calls could both pass this read before either writes).
  const existing = await paymentRef.get();
  if (existing.exists) {
    const data = existing.data() as Record<string, unknown>;
    if (data.status === "verified" || data.status === "paid") {
      return { committed: false, reservationStatus: "already_committed" };
    }
  }

  const reservationIdSnap = await orderRef.get();
  const reservationId = reservationIdSnap.get("reservationId") as string | undefined;
  if (!reservationId) {
    throw new https.HttpsError("failed-precondition", "Order has no reservation.");
  }

  // TODO(audit): `commitReservation` runs its own Firestore transaction
  // OUTSIDE the order/payment transaction below. If this call succeeds (stock
  // decremented, reservation marked "committed") but the order/payment
  // transaction then fails, stock is decremented but the order remains
  // `pending_payment` — leaving a half-committed state that requires manual
  // recovery. Fixing this requires merging both transactions into one (or
  // sequencing them so commitReservation is reversible on downstream failure).
  // Left as-is because the recovery semantics need a design decision.
  const commit = await commitReservation(reservationId);
  if (commit.status === "missing") {
    throw new https.HttpsError("failed-precondition", "Reservation missing.");
  }

  // The transaction does the AUTHORITATIVE idempotency check by re-reading
  // `paymentRef` inside `tx.get`. Two concurrent webhook calls would both pass
  // the pre-check above, but Firestore's pessimistic transaction locking
  // serialises the second one's `tx.get(paymentRef)` until the first commits,
  // so the second sees `status: "verified"` and bails with `committed: false`.
  const txResult = await db.runTransaction(async (tx) => {
    const pSnap = await tx.get(paymentRef);
    if (pSnap.exists) {
      const pData = pSnap.data() as Record<string, unknown>;
      if (pData.status === "verified" || pData.status === "paid") {
        return { committed: false, reservationStatus: "already_committed" as const };
      }
    }
    const oSnap = await tx.get(orderRef);
    if (!oSnap.exists) {
      // Order vanished between the pre-check and now — abort without writing
      // (avoids leaving a paid payment doc pointing at a non-existent order).
      return { committed: false, reservationStatus: commit.status as CommitResult["status"] };
    }
    tx.set(
      orderRef,
      {
        status: "confirmed",
        paymentStatus: "paid",
        paymentProvider: args.provider,
        paymentId: args.paymentId,
        confirmedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    tx.set(
      paymentRef,
      {
        id: args.paymentId,
        provider: args.provider,
        orderId: args.orderId,
        gatewayRef: args.gatewayRef,
        amountPoisha: args.amountPoisha,
        status: "verified",
        gatewayPayload: sanitise(args.gatewayPayload),
        verifiedAt: FieldValue.serverTimestamp(),
        serverVerifiedAt: Timestamp.now(),
      },
      { merge: true },
    );
    return { committed: true, reservationStatus: commit.status as CommitResult["status"] };
  });

  if (txResult.committed) {
    await recordAudit({
      actorUid: null,
      action: "payment.webhook_verified",
      targetType: "payment",
      targetId: args.paymentId,
      after: { provider: args.provider, orderId: args.orderId, reservationStatus: txResult.reservationStatus },
    });
  }

  return txResult;
}
