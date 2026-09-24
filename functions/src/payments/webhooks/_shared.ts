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

  // Idempotency: if the payment doc is already verified/paid, bail.
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

  const commit = await commitReservation(reservationId);
  if (commit.status === "missing") {
    throw new https.HttpsError("failed-precondition", "Reservation missing.");
  }

  await db.runTransaction(async (tx) => {
    const oSnap = await tx.get(orderRef);
    if (!oSnap.exists) return;
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
  });

  await recordAudit({
    actorUid: null,
    action: "payment.webhook_verified",
    targetType: "payment",
    targetId: args.paymentId,
    after: { provider: args.provider, orderId: args.orderId, reservationStatus: commit.status },
  });

  return { committed: true, reservationStatus: commit.status };
}
