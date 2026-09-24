/**
 * Internal helper (NOT a callable): commit a reservation when a payment
 * succeeds. This performs the actual stock decrement.
 *
 * The flow is:
 *   1. Within a Firestore transaction, read `inventoryReservations/{id}`.
 *   2. If status !== 'reserved', return idempotently (already committed /
 *      released / cancelled). Never throw on a duplicate webhook.
 *   3. For each item, decrement `products/{productId}.stock` by quantity,
 *      decrement `products/{productId}.reservedStock` by quantity,
 *      increment `products/{ProductId}.soldStock` by quantity.
 *   4. Mark reservation status='committed', set committedAt.
 *
 * Returns the reservation status so the caller knows whether to write the
 * payment doc / order status update.
 *
 * Exposed so webhook handlers and `verifyPayment` can both call it.
 */
import { db, FieldValue, Timestamp } from "../admin";

export interface CommitResult {
  reservationId: string;
  status: "committed" | "already_committed" | "released" | "missing";
  orderId?: string | null;
}

export async function commitReservation(
  reservationId: string,
): Promise<CommitResult> {
  const reservationRef = db.doc(`inventoryReservations/${reservationId}`);

  const result = await db.runTransaction(async (tx) => {
    const snap = await tx.get(reservationRef);
    if (!snap.exists) {
      return { status: "missing" as const, orderId: null };
    }
    const r = snap.data() as Record<string, unknown>;
    const status = String(r.status ?? "");

    if (status === "committed") {
      return {
        status: "already_committed" as const,
        orderId: (r.orderId as string | null) ?? null,
      };
    }
    if (status !== "reserved") {
      return { status: "released" as const, orderId: null };
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
      const stock = Number(p.stock ?? 0);
      const reservedStock = Number(p.reservedStock ?? 0);
      const soldStock = Number(p.soldStock ?? 0);
      tx.set(
        pRef,
        {
          stock: Math.max(0, stock - it.quantity),
          reservedStock: Math.max(0, reservedStock - it.quantity),
          soldStock: soldStock + it.quantity,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }

    tx.set(
      reservationRef,
      {
        status: "committed",
        committedAt: Timestamp.now(),
      },
      { merge: true },
    );

    return {
      status: "committed" as const,
      orderId: (r.orderId as string | null) ?? null,
    };
  });

  return { reservationId, ...result };
}
