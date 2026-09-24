/**
 * Trigger: `onDocumentCreated('users/{uid}')`.
 *
 * When a new user profile lands in Firestore we synchronously set their
 * Firebase Auth custom claim `role: 'customer'` (the default role). This
 * guarantees that Firestore rules and other Cloud Functions can trust the
 * claim on the very next request — no client-side role assignment, no email
 * inference, no race window where a freshly-signed-up user has no claim.
 *
 * The function is idempotent: if the user already has a role claim, it is
 * preserved. (Manual provisioning by an admin overrides this default.)
 */
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onCall } from "firebase-functions/v2/https";
import { auth, db, assertAuth, type Role } from "../admin";
import { recordAudit } from "../audit/auditLog";

export async function handleUserCreation(uid: string, requestedRole?: Role): Promise<Role> {
  const allowed: Role[] = [
    "admin",
    "staff",
    "rider",
    "logistic",
    "reseller",
    "customer",
  ];
  const role: Role = (requestedRole && allowed.includes(requestedRole)) ? requestedRole : "customer";

  const existing = await auth.getUser(uid).then((u) => u.customClaims ?? {});
  // Only set the default customer claim when no privileged claim exists
  // yet. This prevents a self-signup escalation if the doc says "admin".
  if (existing && (existing.role || existing.admin)) {
    // Already has an explicit role assigned by an admin — respect it.
    await db
      .doc(`users/${uid}`)
      .set({ role: existing.role, claimSyncedAt: Date.now() }, { merge: true });
    return (existing.role as Role) || "customer";
  }

  await auth.setCustomUserClaims(uid, {
    role,
    admin: role === "admin",
  });

  // Make the role visible in the Firestore profile too (single source of
  // truth for the client's UI; the claim is the trust anchor).
  await db.doc(`users/${uid}`).set({ role }, { merge: true });

  await recordAudit({
    actorUid: null,
    action: "user.default_role_assigned",
    targetType: "user",
    targetId: uid,
    after: { role, admin: role === "admin" },
  });

  return role;
}

export const onUserCreate = onDocumentCreated(
  { document: "users/{uid}", region: "asia-southeast1" },
  async (event) => {
    const uid = event.params.uid;
    const snapshot = event.data;
    if (!uid || !snapshot) return;

    const data = snapshot.data();
    if (!data) return;

    try {
      await handleUserCreation(uid, data.role as Role | undefined);
    } catch (err) {
      console.error(`[onUserCreate] failed for uid=${uid}:`, err);
    }
  },
);

export const onUserCreateCallable = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    const authCtx = assertAuth(req);
    const role = await handleUserCreation(authCtx.uid, req.data?.role);
    return { success: true, role };
  },
);
