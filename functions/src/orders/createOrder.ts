/**
 * Callable `createOrder`.
 *
 * The Flutter client NEVER supplies totals. It only forwards the
 * **signed pricing snapshot** + reservationId + addressId + paymentMethod.
 * We verify the signature, double-check the reservation belongs to the
 * caller and is still `reserved`, then write the order doc with the
 * server-computed totals (sourced from the reservation, which was sourced
 * from the snapshot — never from the client).
 *
 * Status is `pending_payment` and `paymentStatus` is `unpaid` until the
 * payment webhook/verifyPayment flips it to `confirmed` / `paid`.
 *
 * The reservation doc is linked to the new orderId atomically so we don't
 * leak inventory into a half-committed order.
 */
import { onCall } from "firebase-functions/v2/https";
import { db, assertAuth, FieldValue, Timestamp } from "../admin";
import {
  errInvalidArgument,
  errFailedPrecondition,
  errNotFound,
  nowMs,
  poishaToTaka,
  verifySnapshot,
} from "../shared/security";
import { recordAudit } from "../audit/auditLog";

type PaymentMethod = "bkash" | "nagad" | "sslcommerz" | "bank_transfer" | "cod";
const METHODS: PaymentMethod[] = ["bkash", "nagad", "sslcommerz", "bank_transfer", "cod"];

interface Snapshot {
  version: "v1";
  items: Array<{
    productId: string;
    name: string;
    nameBn: string;
    sku: string;
    imageUrl: string;
    unitPricePoisha: number;
    quantity: number;
    lineTotalPoisha: number;
    tierApplied: string;
  }>;
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

export interface CreateOrderInput {
  snapshot: Snapshot;
  signature: string;
  reservationId: string;
  addressId?: string;
  paymentMethod: PaymentMethod;
  note?: string;
}

export const createOrder = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const authCtx = assertAuth(req);
    const uid = authCtx.uid;
    const input = (req.data ?? {}) as Partial<CreateOrderInput>;

    const snapshot = input.snapshot;
    const signature = input.signature;
    const reservationId = (input.reservationId ?? "").toString().trim();
    const paymentMethod = input.paymentMethod as PaymentMethod | undefined;
    const note = input.note?.toString().trim();

    if (!snapshot || typeof signature !== "string") {
      errInvalidArgument("snapshot and signature are required.");
    }
    if (!reservationId) errInvalidArgument("reservationId is required.");
    if (!paymentMethod || !METHODS.includes(paymentMethod)) {
      errInvalidArgument(
        `paymentMethod must be one of ${METHODS.join(", ")}.`,
      );
    }
    if (!verifySnapshot(snapshot, signature)) {
      errFailedPrecondition("Pricing snapshot signature is invalid.");
    }
    if (nowMs() > snapshot.expiresAtMs) {
      errFailedPrecondition("Pricing snapshot expired; restart checkout.");
    }

    // Re-derive caller profile fields for the order doc (denormalised so the
    // admin panel can render an order without a secondary lookup).
    const userSnap = await db.doc(`users/${uid}`).get();
    const userData = (userSnap.data() ?? {}) as Record<string, unknown>;
    const addresses = (userData.addresses ?? []) as Array<Record<string, unknown>>;
    const addressId = input.addressId ?? snapshot.addressId ?? null;
    const address = addressId
      ? addresses.find((a) => String(a.id) === String(addressId)) ?? null
      : null;
    if (!address && paymentMethod !== "cod") {
      errInvalidArgument("A delivery address is required.");
    }

    const orderRef = db.collection("orders").doc();
    const reservationRef = db.doc(`inventoryReservations/${reservationId}`);

    let orderId: string;
    try {
      orderId = await db.runTransaction(async (tx) => {
        const rSnap = await tx.get(reservationRef);
        if (!rSnap.exists) {
          errNotFound(`Reservation ${reservationId} not found.`);
        }
        const r = rSnap.data() as Record<string, unknown>;
        const status = String(r.status ?? "");
        if (status !== "reserved") {
          errFailedPrecondition(
            `Reservation is ${status}; cannot create order.`,
          );
        }
        if (String(r.userId) !== uid) {
          errFailedPrecondition("Reservation does not belong to you.");
        }
        // Bind the new orderId to the reservation so commitReservation knows
        // which order to mark paid once the payment webhook fires.
        tx.set(reservationRef, { orderId: orderRef.id }, { merge: true });

        const items = (r.items ?? snapshot.items) as Array<Record<string, unknown>>;

        tx.set(orderRef, {
          id: orderRef.id,
          customerUid: uid,
          customerName: String(userData.name ?? ""),
          customerPhone: String(userData.phone ?? ""),
          customerEmail: String(userData.email ?? ""),
          items: items.map((it) => ({
            productId: String(it.productId),
            productName: String(it.name ?? ""),
            productNameBn: String(it.nameBn ?? ""),
            sku: String(it.sku ?? ""),
            imageUrl: String(it.imageUrl ?? ""),
            unitPricePoisha: Number(it.unitPricePoisha ?? 0),
            quantity: Number(it.quantity ?? 0),
            lineTotalPoisha: Number(it.lineTotalPoisha ?? 0),
            tierApplied: String(it.tierApplied ?? "retail"),
            unitPrice: poishaToTaka(Number(it.unitPricePoisha ?? 0)),
            lineTotal: poishaToTaka(Number(it.lineTotalPoisha ?? 0)),
          })),
          subtotalPoisha: Number(r.subtotalPoisha ?? snapshot.subtotalPoisha),
          deliveryFeePoisha: Number(
            r.deliveryFeePoisha ?? snapshot.deliveryFeePoisha,
          ),
          discountPoisha: Number(r.discountPoisha ?? snapshot.discountPoisha),
          grandTotalPoisha: Number(
            r.grandTotalPoisha ?? snapshot.grandTotalPoisha,
          ),
          // Convenience floats for the client (read-only).
          subtotal: poishaToTaka(Number(r.subtotalPoisha ?? snapshot.subtotalPoisha)),
          deliveryFee: poishaToTaka(
            Number(r.deliveryFeePoisha ?? snapshot.deliveryFeePoisha),
          ),
          discount: poishaToTaka(
            Number(r.discountPoisha ?? snapshot.discountPoisha),
          ),
          total: poishaToTaka(
            Number(r.grandTotalPoisha ?? snapshot.grandTotalPoisha),
          ),
          address: address
            ? {
                id: String(address.id),
                name: String(address.name ?? ""),
                district: String(address.district ?? ""),
                upazila: String(address.upazila ?? ""),
                station: String(address.station ?? ""),
                area: String(address.area ?? ""),
                detailedAddress: String(address.detailedAddress ?? ""),
                phone: String(address.phone ?? userData.phone ?? ""),
              }
            : null,
          paymentMethod,
          paymentStatus: "unpaid",
          status: "pending_payment",
          reservationId,
          pricingVersion: snapshot.version,
          businessId: snapshot.businessId ?? null,
          couponCode: r.couponCode ?? snapshot.couponCode ?? null,
          note: note ?? null,
          isEmergency: false,
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
          serverCreatedAt: Timestamp.now(),
        });
        return orderRef.id;
      });
    } catch (err) {
      if (err instanceof Error && err.constructor.name === "HttpsError") throw err;
      console.error("[createOrder] transaction failed:", err);
      throw err;
    }

    await recordAudit({
      actorUid: uid,
      action: "order.created",
      targetType: "order",
      targetId: orderId,
      after: { reservationId, paymentMethod },
    });

    return { orderId };
  },
);
