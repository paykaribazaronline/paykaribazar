/**
 * Callable `reserveStock`.
 *
 * The caller passes the **signed pricing snapshot** produced by `calcOrder`.
 * We verify the HMAC, check the 10-minute expiry window, then run a Firestore
 * transaction that atomically:
 *   - For each line item, checks `stock - reservedStock >= quantity` on
 *     `products/{productId}`.
 *   - Increments `products/{productId}.reservedStock`.
 *   - Writes a `inventoryReservations/{reservationId}` doc with `status:
 *     'reserved'`, the items, the userId, and `expiresAt = now + 15min`.
 *
 * If any single line item fails the availability check, the entire
 * transaction aborts and we throw `failed-precondition` with the offending
 * productId. The Flutter client shows the user a "stock changed" dialog.
 *
 * Reservations expire automatically — a scheduled sweep or a follow-up
 * `releaseReservation` call will decrement `reservedStock` once expired.
 */
import { onCall } from "firebase-functions/v2/https";
import { db, assertAuth, Timestamp } from "../admin";
import {
  errInvalidArgument,
  errFailedPrecondition,
  nowMs,
  RESERVATION_TTL_MS,
  verifySnapshot,
} from "../shared/security";
import { recordAudit } from "../audit/auditLog";

// Mirrors PricingSnapshot in calcOrder.ts. Duplicated intentionally so this
// module is independently audit-friendly.
interface LineSnapshot {
  productId: string;
  unitPricePoisha: number;
  quantity: number;
  lineTotalPoisha: number;
  name: string;
  nameBn: string;
  sku: string;
  imageUrl: string;
  tierApplied: string;
  stockAtCalc: number;
  reservedStockAtCalc: number;
}
interface PricingSnapshot {
  version: "v1";
  items: LineSnapshot[];
  subtotalPoisha: number;
  deliveryFeePoisha: number;
  discountPoisha: number;
  grandTotalPoisha: number;
  couponCode: string | null;
  addressId: string | null;
  businessId: string | null;
  issuedAtMs: number;
  expiresAtMs: number;
}

export interface ReserveStockInput {
  snapshot: PricingSnapshot;
  signature: string;
}

export interface ReserveStockOutput {
  reservationId: string;
  expiresAt: number;
}

export const reserveStock = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const authCtx = assertAuth(req);
    const uid = authCtx.uid;
    const input = (req.data ?? {}) as Partial<ReserveStockInput>;

    const snapshot = input.snapshot;
    const signature = input.signature;
    if (!snapshot || typeof signature !== "string") {
      errInvalidArgument("snapshot and signature are required.");
    }
    if (snapshot.version !== "v1") {
      errInvalidArgument("Unsupported snapshot version.");
    }
    if (!Array.isArray(snapshot.items) || snapshot.items.length === 0) {
      errInvalidArgument("snapshot.items[] is empty.");
    }
    if (!verifySnapshot(snapshot, signature)) {
      errFailedPrecondition("Pricing snapshot signature is invalid or tampered.");
    }
    if (nowMs() > snapshot.expiresAtMs) {
      errFailedPrecondition("Pricing snapshot has expired; please re-run calcOrder.");
    }

    const expiresAtMs = nowMs() + RESERVATION_TTL_MS;
    const reservationRef = db.collection("inventoryReservations").doc();

    try {
      await db.runTransaction(async (tx) => {
        // Re-read each product inside the transaction so we hold locks.
        const productRefs = snapshot.items.map((it) =>
          db.doc(`products/${it.productId}`),
        );
        const snaps = await tx.getAll(...productRefs);

        for (const [i, line] of snapshot.items.entries()) {
          const pSnap = snaps[i];
          if (!pSnap || !pSnap.exists) {
            errFailedPrecondition(
              `Product ${line.productId} no longer exists.`,
              { productId: line.productId },
            );
          }
          const p = pSnap!.data() as Record<string, unknown>;
          const stock = Number(p.stock ?? 0);
          const reserved = Number(p.reservedStock ?? 0);
          const available = stock - reserved;
          if (available < line.quantity) {
            errFailedPrecondition(
              `Insufficient stock for ${p.name} (have ${available}, want ${line.quantity}).`,
              { productId: line.productId, available, wanted: line.quantity },
            );
          }
          tx.set(
            pSnap.ref,
            { reservedStock: reserved + line.quantity },
            { merge: true },
          );
        }

        tx.set(reservationRef, {
          id: reservationRef.id,
          userId: uid,
          orderId: null,
          status: "reserved",
          items: snapshot.items.map((l) => ({
            productId: l.productId,
            name: l.name,
            nameBn: l.nameBn,
            sku: l.sku,
            imageUrl: l.imageUrl,
            unitPricePoisha: l.unitPricePoisha,
            quantity: l.quantity,
            lineTotalPoisha: l.lineTotalPoisha,
            tierApplied: l.tierApplied,
          })),
          subtotalPoisha: snapshot.subtotalPoisha,
          deliveryFeePoisha: snapshot.deliveryFeePoisha,
          discountPoisha: snapshot.discountPoisha,
          grandTotalPoisha: snapshot.grandTotalPoisha,
          couponCode: snapshot.couponCode,
          addressId: snapshot.addressId,
          businessId: snapshot.businessId,
          pricingVersion: snapshot.version,
          createdAt: Timestamp.now(),
          expiresAt: Timestamp.fromMillis(expiresAtMs),
        });
      });
    } catch (err) {
      // HttpsError thrown by errFailedPrecondition propagates as-is.
      if (err instanceof Error && err.constructor.name === "HttpsError") {
        throw err;
      }
      console.error("[reserveStock] transaction failed:", err);
      throw err;
    }

    await recordAudit({
      actorUid: uid,
      action: "reservation.created",
      targetType: "reservation",
      targetId: reservationRef.id,
      after: { expiresAtMs, itemCount: snapshot.items.length },
    });

    return {
      reservationId: reservationRef.id,
      expiresAt: expiresAtMs,
    } satisfies ReserveStockOutput;
  },
);
