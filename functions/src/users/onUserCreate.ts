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
import { auth, db, type Role } from "../admin";
import { recordAudit } from "../audit/auditLog";

export const onUserCreate = onDocumentCreated(
  { document: "users/{uid}", region: "asia-southeast1" },
  async (event) => {
    const uid = event.params.uid;
    const snapshot = event.data;
    if (!uid || !snapshot) return;

    const data = snapshot.data();
    if (!data) return;

    const requestedRole = (data.role as Role | undefined) ?? "customer";
    const allowed: Role[] = [
      "admin",
      "staff",
      "rider",
      "logistic",
      "reseller",
      "customer",
    ];
    const role: Role = allowed.includes(requestedRole) ? requestedRole : "customer";

    try {
      const existing = await auth.getUser(uid).then((u) => u.customClaims ?? {});
      // Only set the default customer claim when no privileged claim exists
      // yet. This prevents a self-signup escalation if the doc says "admin".
      if (existing && (existing.role || existing.admin)) {
        // Already has an explicit role assigned by an admin — respect it.
        await db
          .doc(`users/${uid}`)
          .set({ role: existing.role, claimSyncedAt: Date.now() }, { merge: true });
        return;
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
    } catch (err) {
      // If the Auth user doesn't exist yet (signup race), the trigger will
      // simply no-op; the next time claims are needed they'll be re-derived.
      console.error(`[onUserCreate] failed for uid=${uid}:`, err);
    }
  },
);
