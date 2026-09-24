/**
 * Admin-only: provision a staff member (or any non-customer role).
 *
 * The Flutter admin app must NOT create Firebase Auth users directly or write
 * the `users/{uid}` profile with a role field — that was the original
 * escalation bug. This function is the single chokepoint.
 *
 * Flow:
 *   1. Caller's custom claim `role === 'admin'` is verified (assertAdmin).
 *   2. Input is validated (email, optional phone, displayName, role).
 *   3. If the Auth user exists, we link to it; otherwise we create it.
 *   4. Custom claims `{role, admin: role==='admin'}` are set atomically.
 *   5. The `/users/{uid}` profile is written with role, provenance and a
 *      server timestamp. No client can ever set this themselves because the
 *      Firestore rules deny `role` writes to non-admin callers.
 *   6. An audit entry is appended.
 */
import { onCall } from "firebase-functions/v2/https";
import { auth, db, assertAdmin, ALL_ROLES, type Role } from "../admin";
import { recordAudit } from "../audit/auditLog";
import {
  errInvalidArgument,
  errPermissionDenied,
} from "../shared/security";

export interface ProvisionStaffInput {
  email: string;
  phone?: string;
  displayName?: string;
  password?: string;
  role: Role;
}

export const provisionStaff = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const caller = assertAdmin(req);
    const input = (req.data ?? {}) as Partial<ProvisionStaffInput>;

    const email = (input.email ?? "").toString().trim().toLowerCase();
    const role = input.role as Role | undefined;
    const phone = input.phone?.toString().trim();
    const displayName = input.displayName?.toString().trim();
    const password = input.password?.toString();

    if (!email || !email.includes("@")) {
      errInvalidArgument("A valid email is required.");
    }
    if (!role || !ALL_ROLES.includes(role)) {
      errInvalidArgument(`role must be one of ${ALL_ROLES.join(", ")}.`);
    }
    if (role === "customer") {
      errPermissionDenied(
        "Use the regular signup flow for customers — do not provision them here.",
      );
    }

    let uid: string;
    let created = false;
    try {
      const existing = await auth.getUserByEmail(email);
      uid = existing.uid;
    } catch (notFound) {
      if (!password || password.length < 8) {
        errInvalidArgument(
          "New staff must have an initial password of at least 8 characters.",
        );
      }
      const createdUser = await auth.createUser({
        email,
        password,
        displayName: displayName ?? undefined,
        phoneNumber: phone ?? undefined,
        emailVerified: false,
        disabled: false,
      });
      uid = createdUser.uid;
      created = true;
    }

    const claims = { role, admin: role === "admin" };
    await auth.setCustomUserClaims(uid, claims);

    const profile = {
      id: uid,
      email,
      phone: phone ?? null,
      name: displayName ?? "",
      role,
      admin: role === "admin",
      provisionedAt: Date.now(),
      provisionedBy: caller.uid,
      provisionedByEmail: caller.token.email ?? null,
    };
    await db.doc(`users/${uid}`).set(profile, { merge: true });

    await recordAudit({
      actorUid: caller.uid,
      action: created ? "staff.provisioned" : "staff.role_updated",
      targetType: "user",
      targetId: uid,
      before: { created },
      after: profile,
      metadata: { callerEmail: caller.token.email ?? null },
    });

    return { uid, role, created };
  },
);
