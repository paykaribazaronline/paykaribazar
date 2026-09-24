/**
 * THE CORE PRICING ENGINE — `calcOrder`.
 *
 * Why this function exists: the Flutter client was computing order totals,
 * discounts and delivery fees locally, then writing them straight to Firestore.
 * A user could swap the price of any product to 0 before placing an order. This
 * function moves all pricing server-side and produces a **signed pricing
 * snapshot** that downstream callables (reserveStock / createOrder) verify.
 *
 * Pipeline (no mutations, no reservations — purely deterministic compute):
 *   1. Read each product doc in a single Firestore `getAll` batch.
 *   2. Resolve per-line unit price:
 *        a. Prefer `productPrices/{productId}` (B2B contract price) if present.
 *        b. Else fall back to the product's `tieredPrices` based on quantity.
 *        c. Else `wholesalePrice` if the qty ≥ `minWholesaleQty`.
 *        d. Else `price` (the retail price).
 *   3. Enforce MOQ (`minWholesaleQty`) when the product is wholesale-only.
 *   4. Compute subtotal in integer poisha.
 *   5. Resolve delivery fee from `settings/delivery_zones` by matching the
 *      caller's address (from `users/{uid}.addresses`).
 *   6. Validate coupon (transactional): active, not expired, ≥ minOrderValue,
 *      uses < maxUses, caller not in `usedBy`. Discount capped to subtotal.
 *   7. Build the snapshot, HMAC-sign it, return it with `expiresAt = +10min`.
 *
 * Money is computed in integer poisha (1 taka = 100 poisha) end-to-end.
 * Output converts back to taka (float) for the Flutter client.
 */
import { onCall } from "firebase-functions/v2/https";
import { db, assertAuth } from "../admin";
import {
  canonicalJson,
  errInvalidArgument,
  errNotFound,
  errFailedPrecondition,
  poishaToTaka,
  signSnapshot,
  takaToPoisha,
  PRICING_TTL_MS,
  nowMs,
} from "../shared/security";

// ------------------------------ types --------------------------------------

interface CalcItem {
  productId: string;
  quantity: number;
  variantId?: string;
}

interface CalcOrderInput {
  items: CalcItem[];
  addressId?: string;
  couponCode?: string;
  businessId?: string;
}

interface LineSnapshot {
  productId: string;
  name: string;
  nameBn: string;
  sku: string;
  imageUrl: string;
  unitPricePoisha: number;
  quantity: number;
  lineTotalPoisha: number;
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

interface CalcOrderOutput {
  pricingVersion: string;
  unitPrices: { productId: string; unitPrice: number; tierApplied: string }[];
  lineTotals: { productId: string; lineTotal: number; quantity: number }[];
  subtotal: number;
  deliveryFee: number;
  discount: number;
  grandTotal: number;
  couponCode: string | null;
  couponValid: boolean;
  stockSnapshots: { productId: string; stock: number; reservedStock: number }[];
  expiresAt: number;
  signature: string;
  snapshot: PricingSnapshot;
}

// ------------------------------ helpers ------------------------------------

/** Resolve the unit price for a quantity, returning the poisha amount and
 *  a human label describing which tier was applied. */
function resolveUnitPrice(
  product: Record<string, unknown>,
  contractPrice: number | null,
  quantity: number,
): { pricePoisha: number; tierApplied: string } {
  if (contractPrice !== null && contractPrice > 0) {
    return {
      pricePoisha: takaToPoisha(contractPrice),
      tierApplied: "contract",
    };
  }
  const tiered = (product.tieredPrices ?? {}) as Record<string, number>;
  for (const [range, tPrice] of Object.entries(tiered)) {
    const startEnd = parseTierRange(range);
    if (!startEnd) continue;
    const { start, end } = startEnd;
    const inRange = end === null ? quantity >= start : quantity >= start && quantity <= end;
    if (inRange) {
      return { pricePoisha: takaToPoisha(tPrice), tierApplied: `tier:${range}` };
    }
  }
  const wholesale = product.wholesalePrice as number | undefined;
  const minWholesaleQty = (product.minWholesaleQty as number | undefined) ?? 0;
  if (typeof wholesale === "number" && wholesale > 0 && quantity >= minWholesaleQty) {
    return {
      pricePoisha: takaToPoisha(wholesale),
      tierApplied: "wholesale",
    };
  }
  const retail = (product.price as number | undefined) ?? 0;
  return { pricePoisha: takaToPoisha(retail), tierApplied: "retail" };
}

function parseTierRange(range: string): { start: number; end: number | null } | null {
  const r = range.trim();
  if (r.endsWith("+")) {
    const start = parseInt(r.slice(0, -1).trim(), 10);
    if (Number.isNaN(start)) return null;
    return { start, end: null };
  }
  if (r.includes("-")) {
    const parts = r.split("-").map((p) => p.trim());
    const a = parts[0] ?? "";
    const b = parts[1] ?? "";
    const start = parseInt(a, 10);
    const end = parseInt(b, 10);
    if (Number.isNaN(start) || Number.isNaN(end)) return null;
    return { start, end };
  }
  const single = parseInt(r, 10);
  if (Number.isNaN(single)) return null;
  return { start: single, end: single };
}

// ------------------------------ main callable ------------------------------

export const calcOrder = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const authCtx = assertAuth(req);
    const uid = authCtx.uid;
    const input = (req.data ?? {}) as Partial<CalcOrderInput>;

    const items = Array.isArray(input.items) ? input.items : [];
    if (items.length === 0) {
      errInvalidArgument("items[] is required and must be non-empty.");
    }
    for (const [i, it] of items.entries()) {
      if (!it || typeof it.productId !== "string" || !it.productId) {
        errInvalidArgument(`items[${i}].productId is required.`);
      }
      if (!Number.isInteger(it.quantity) || it.quantity <= 0) {
        errInvalidArgument(`items[${i}].quantity must be a positive integer.`);
      }
    }

    // ---------- 1. Batch-read products + contract prices ------------------
    const productRefs = items.map((it) => db.doc(`products/${it.productId}`));
    const productSnaps = await db.getAll(...productRefs);
    const contractRefs = items.map((it) => db.doc(`productPrices/${it.productId}`));
    const contractSnaps = await db.getAll(...contractRefs);

    // ---------- 2. Resolve unit prices + enforce MOQ -----------------------
    const lineSnapshots: LineSnapshot[] = [];
    for (const [i, it] of items.entries()) {
      const snap = productSnaps[i];
      if (!snap || !snap.exists) {
        errNotFound(`Product ${it.productId} not found.`);
      }
      const product = snap!.data() as Record<string, unknown>;

      const moq = (product.minWholesaleQty as number | undefined) ?? 0;
      const isWholesaleOnly = Boolean(product.wholesaleOnly);
      if (isWholesaleOnly && moq > 0 && it.quantity < moq) {
        errFailedPrecondition(
          `Product ${product.name} requires a minimum of ${moq} units.`,
        );
      }

      const contractSnap = contractSnaps[i];
      const contractRaw = contractSnap?.data();
      const contractPrice =
        contractRaw && typeof contractRaw.unitPrice === "number"
          ? (contractRaw.unitPrice as number)
          : null;

      const { pricePoisha, tierApplied } = resolveUnitPrice(
        product,
        contractPrice,
        it.quantity,
      );
      const stock = (product.stock as number | undefined) ?? 0;
      const reservedStock = (product.reservedStock as number | undefined) ?? 0;
      if (stock - reservedStock < it.quantity) {
        errFailedPrecondition(
          `Insufficient stock for ${product.name} (have ${stock - reservedStock}, want ${it.quantity}).`,
        );
      }

      lineSnapshots.push({
        productId: it.productId,
        name: String(product.name ?? ""),
        nameBn: String(product.nameBn ?? ""),
        sku: String(product.sku ?? ""),
        imageUrl: String(product.imageUrl ?? ""),
        unitPricePoisha: pricePoisha,
        quantity: it.quantity,
        lineTotalPoisha: pricePoisha * it.quantity,
        tierApplied,
        stockAtCalc: stock,
        reservedStockAtCalc: reservedStock,
      });
    }

    // ---------- 3. Subtotal -------------------------------------------------
    const subtotalPoisha = lineSnapshots.reduce(
      (acc, l) => acc + l.lineTotalPoisha,
      0,
    );

    // ---------- 4. Delivery fee ---------------------------------------------
    let deliveryFeePoisha = 0;
    let addressIdResolved: string | null = null;
    if (input.addressId) {
      const userSnap = await db.doc(`users/${uid}`).get();
      const userData = userSnap.data() as Record<string, unknown> | undefined;
      const addresses = (userData?.addresses ?? []) as Array<Record<string, unknown>>;
      const addr = addresses.find((a) => String(a.id) === String(input.addressId));
      if (!addr) {
        errInvalidArgument(`addressId ${input.addressId} not found in your profile.`);
      }
      addressIdResolved = String(addr!.id);

      // Look up delivery zone by area / district / station.
      const zonesSnap = await db.doc("settings/delivery_zones").get();
      const zones = (zonesSnap.data()?.zones ?? []) as Array<Record<string, unknown>>;
      const zone = zones.find((z) => {
        const areas = (z.areas ?? []) as string[];
        const districts = (z.districts ?? []) as string[];
        const stations = (z.stations ?? []) as string[];
        return (
          areas.includes(String(addr!.area)) ||
          districts.includes(String(addr!.district)) ||
          stations.includes(String(addr!.station))
        );
      });
      const fee = zone
        ? Number(zone.fee ?? 0)
        : Number(addr!.deliveryCharge ?? 0);
      deliveryFeePoisha = takaToPoisha(fee);
    }

    // ---------- 5. Coupon (transactional validation, NOT redemption) -------
    let discountPoisha = 0;
    let couponCode: string | null = null;
    let couponValid = false;
    if (input.couponCode) {
      const code = String(input.couponCode).toUpperCase().trim();
      couponCode = code;
      await db.runTransaction(async (tx) => {
        const cRef = db.doc(`coupons/${code}`);
        const cSnap = await tx.get(cRef);
        if (!cSnap.exists) return;
        const c = cSnap.data() as Record<string, unknown>;
        const isActive = Boolean(c.isActive);
        const expiry = c.expiryDate as
          | { toDate?: () => Date; seconds?: number }
          | undefined;
        const expired = expiry
          ? (expiry.toDate?.() ?? new Date((expiry.seconds ?? 0) * 1000)).getTime() < nowMs()
          : false;
        const minOrder = Number(c.minOrderValue ?? 0);
        const maxUses = Number(c.maxUses ?? -1);
        const currentUses = Number(c.currentUses ?? 0);
        const usedBy = (c.usedBy ?? []) as string[];
        if (!isActive) return;
        if (expired) return;
        if (poishaToTaka(subtotalPoisha) < minOrder) return;
        if (maxUses !== -1 && currentUses >= maxUses) return;
        if (usedBy.includes(uid)) return;

        // Compute discount.
        const type = String(c.discountType ?? "fixed");
        const value = Number(c.discountValue ?? 0);
        let disc =
          type === "percentage"
            ? Math.floor((subtotalPoisha * value) / 100)
            : takaToPoisha(value);
        const maxDisc =
          typeof c.maxDiscount === "number"
            ? takaToPoisha(Number(c.maxDiscount))
            : null;
        if (maxDisc !== null && disc > maxDisc) disc = maxDisc;
        if (disc > subtotalPoisha) disc = subtotalPoisha;
        discountPoisha = disc;
        couponValid = true;
      });
    }

    // ---------- 6. Grand total ---------------------------------------------
    const grandTotalPoisha =
      subtotalPoisha + deliveryFeePoisha - discountPoisha;

    // ---------- 7. Build + sign snapshot -----------------------------------
    const issuedAtMs = nowMs();
    const expiresAtMs = issuedAtMs + PRICING_TTL_MS;

    const snapshot: PricingSnapshot = {
      version: "v1",
      items: lineSnapshots,
      subtotalPoisha,
      deliveryFeePoisha,
      discountPoisha,
      grandTotalPoisha,
      couponCode,
      addressId: addressIdResolved,
      businessId: input.businessId ?? null,
      issuedAtMs,
      expiresAtMs,
    };

    const signature = signSnapshot(snapshot);

    const output: CalcOrderOutput = {
      pricingVersion: "v1",
      unitPrices: lineSnapshots.map((l) => ({
        productId: l.productId,
        unitPrice: poishaToTaka(l.unitPricePoisha),
        tierApplied: l.tierApplied,
      })),
      lineTotals: lineSnapshots.map((l) => ({
        productId: l.productId,
        lineTotal: poishaToTaka(l.lineTotalPoisha),
        quantity: l.quantity,
      })),
      subtotal: poishaToTaka(subtotalPoisha),
      deliveryFee: poishaToTaka(deliveryFeePoisha),
      discount: poishaToTaka(discountPoisha),
      grandTotal: poishaToTaka(grandTotalPoisha),
      couponCode,
      couponValid,
      stockSnapshots: lineSnapshots.map((l) => ({
        productId: l.productId,
        stock: l.stockAtCalc,
        reservedStock: l.reservedStockAtCalc,
      })),
      expiresAt: expiresAtMs,
      signature,
      snapshot,
    };

    // Sanity: ensure canonical JSON of the snapshot is stable for the client
    // to echo back; we expose `snapshot` so the client can round-trip it.
    void canonicalJson(snapshot);

    return output;
  },
);
