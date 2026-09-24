/**
 * Coupon redemption helper — called from the createOrder flow AFTER the
 * payment webhook marks the order paid, so we keep a single source of truth
 * and prevent double-redemption.
 *
 * Also exported as a Callable (`redeemCoupon`) for diagnostic / admin use,
 * though the main path is internal.
 *
 * Behaviour (transactional):
 *   - If coupon code is null/empty, no-op.
 *   - If the coupon is inactive, expired, over-maxUses, or already used by
 *     this user, no-op (the discount from calcOrder is rolled back elsewhere).
 *   - Otherwise atomically: currentUses++, usedBy.push(uid).
 *
 * Idempotent: if the user already appears in usedBy, the call returns
 * `alreadyRedeemed: true` without mutating.
 */
import { onCall } from "firebase-functions/v2/https";
import { db, assertAuth } from "../admin";
import { errInvalidArgument } from "../shared/security";
import { recordAudit } from "../audit/auditLog";

export interface RedeemCouponInput {
  couponCode: string;
  orderId?: string;
}

export interface RedeemCouponResult {
  code: string;
  redeemed: boolean;
  alreadyRedeemed: boolean;
  currentUses: number;
}

/** Internal helper — used by the post-payment success flow. */
export async function redeemCouponInternal(
  uid: string,
  rawCode: string,
  orderId?: string,
): Promise<RedeemCouponResult> {
  const code = rawCode.toUpperCase().trim();
  if (!code) {
    return { code: "", redeemed: false, alreadyRedeemed: false, currentUses: 0 };
  }
  const cRef = db.doc(`coupons/${code}`);
  const result = await db.runTransaction(async (tx) => {
    const snap = await tx.get(cRef);
    if (!snap.exists) {
      return { code, redeemed: false, alreadyRedeemed: false, currentUses: 0 };
    }
    const c = snap.data() as Record<string, unknown>;
    const usedBy = (c.usedBy ?? []) as string[];
    if (usedBy.includes(uid)) {
      return {
        code,
        redeemed: false,
        alreadyRedeemed: true,
        currentUses: Number(c.currentUses ?? 0),
      };
    }
    const maxUses = Number(c.maxUses ?? -1);
    const currentUses = Number(c.currentUses ?? 0);
    if (maxUses !== -1 && currentUses >= maxUses) {
      return { code, redeemed: false, alreadyRedeemed: false, currentUses };
    }
    const next = currentUses + 1;
    tx.set(
      cRef,
      { currentUses: next, usedBy: [...usedBy, uid] },
      { merge: true },
    );
    return { code, redeemed: true, alreadyRedeemed: false, currentUses: next };
  });

  if (result.redeemed) {
    await recordAudit({
      actorUid: uid,
      action: "coupon.redeemed",
      targetType: "coupon",
      targetId: code,
      after: result,
      metadata: { orderId: orderId ?? null },
    });
  }
  return result;
}

/** Public Callable — diagnostic / admin / test surface. */
export const redeemCoupon = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const authCtx = assertAuth(req);
    const uid = authCtx.uid;
    const input = (req.data ?? {}) as Partial<RedeemCouponInput>;
    const code = (input.couponCode ?? "").toString().trim();
    if (!code) errInvalidArgument("couponCode is required.");
    return redeemCouponInternal(uid, code, input.orderId);
  },
);
