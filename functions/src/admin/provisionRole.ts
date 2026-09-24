/**
 * Admin-only: change an existing user's role.
 *
 * - Caller must be `admin`.
 * - Target uid must already exist in Auth.
 * - role must be one of {admin, staff, rider, logistic, reseller, customer}.
 * - Custom claim + Firestore profile are updated in a Firestore transaction
 *   (the Auth claim update is sequenced after a successful profile write so
 *   that a failed Auth call doesn't leave a half-mutated profile).
 * - An audit entry is appended capturing before/after.
 *
 * There is no client surface for this — only the admin app can call it, and
 * the Firestore rules block direct profile `role` writes from any client.
 */
import { onCall } from "firebase-functions/v2/https";
import {
  auth,
  db,
  assertAdmin,
  ALL_ROLES,
  type Role,
} from "../admin";
import { recordAudit } from "../audit/auditLog";
import { errInvalidArgument, errNotFound } from "../shared/security";

export interface SetUserRoleInput {
  uid: string;
  role: Role;
  reason?: string;
}

export const setUserRole = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const caller = assertAdmin(req);
    const input = (req.data ?? {}) as Partial<SetUserRoleInput>;

    const uid = (input.uid ?? "").toString().trim();
    const role = input.role as Role | undefined;
    const reason = input.reason?.toString().trim();

    if (!uid) errInvalidArgument("uid is required.");
    if (!role || !ALL_ROLES.includes(role)) {
      errInvalidArgument(`role must be one of ${ALL_ROLES.join(", ")}.`);
    }

    // Fetch the user (Auth) and the existing profile (Firestore) up front so
    // we can record a meaningful `before` snapshot in the audit log.
    let userRecord;
    try {
      userRecord = await auth.getUser(uid);
    } catch {
      errNotFound(`No Firebase Auth user with uid=${uid}.`);
    }
    const priorClaims = (userRecord!.customClaims ?? {}) as {
      role?: Role;
      admin?: boolean;
    };

    const profileRef = db.doc(`users/${uid}`);
    const newClaims = { role, admin: role === "admin" };

    await db.runTransaction(async (tx) => {
      const snap = await tx.get(profileRef);
      if (!snap.exists) {
        errNotFound(`No /users/${uid} profile. Use provisionStaff first.`);
      }
      tx.set(
        profileRef,
        {
          role,
          admin: role === "admin",
          roleUpdatedAt: Date.now(),
          roleUpdatedBy: caller.uid,
        },
        { merge: true },
      );
    });

    // Apply the Auth claim AFTER the profile transaction succeeds.
    await auth.setCustomUserClaims(uid, newClaims);

    await recordAudit({
      actorUid: caller.uid,
      action: "user.role_changed",
      targetType: "user",
      targetId: uid,
      before: priorClaims,
      after: newClaims,
      metadata: { reason: reason ?? null },
    });

    return { uid, role, admin: role === "admin" };
  },
);
