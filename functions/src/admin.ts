/**
 * Shared admin / Firestore / Auth singletons.
 *
 * In Cloud Functions (2nd gen) every cold start should call `initializeApp`
 * exactly once. We use `applicationDefault()` which trusts the runtime service
 * account attached to the function. For local emulation, the
 * `FIREBASE_ADMIN_SERVICE_ACCOUNT_JSON` env (path or base64 of inline JSON)
 * overrides that for testing.
 */
import * as admin from "firebase-admin";
import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

/** Auth context shape (CallableRequest["auth"] from firebase-functions v2). */
type AuthData = NonNullable<CallableRequest["auth"]>;

// `process.env.FIREBASE_ADMIN_SERVICE_ACCOUNT_JSON` may be a filesystem path
// OR a base64-encoded JSON blob. We resolve either to a credential object.
function resolveCredential(): admin.credential.Credential {
  const raw = process.env.FIREBASE_ADMIN_SERVICE_ACCOUNT_JSON?.trim();
  if (!raw) {
    return admin.credential.applicationDefault();
  }
  // If it looks like a path, read the file.
  if (raw.endsWith(".json") || raw.startsWith("/")) {
    return admin.credential.cert(raw);
  }
  // Otherwise treat as base64 JSON.
  try {
    const json = Buffer.from(raw, "base64").toString("utf8");
    return admin.credential.cert(JSON.parse(json));
  } catch (err) {
    // Last resort: assume it is already JSON.
    return admin.credential.cert(JSON.parse(raw));
  }
}

if (admin.apps.length === 0) {
  admin.initializeApp({ credential: resolveCredential() });
}

export const app = admin.app();
export const auth = admin.auth();
export const db = admin.firestore();
export const FieldValue = admin.firestore.FieldValue;
export const Timestamp = admin.firestore.Timestamp;

/** Roles recognised by the backend. Mirrors the Flutter UserRole enum. */
export type Role =
  | "admin"
  | "staff"
  | "rider"
  | "logistic"
  | "reseller"
  | "customer";

export const ALL_ROLES: Role[] = [
  "admin",
  "staff",
  "rider",
  "logistic",
  "reseller",
  "customer",
];

/**
 * Extract role from a Callable request's custom claims. The shape is
 * `{ role: Role, admin: boolean }`. `admin` is set to true only when role is
 * admin, so a single check suffices in most callables.
 */
function extractRole(authCtx: AuthData | undefined): Role | null {
  if (!authCtx) return null;
  const token = authCtx.token as Record<string, unknown> | undefined;
  const role = token?.["role"] as Role | undefined;
  return role ?? null;
}

/**
 * Assert that the caller is authenticated. Throws `unauthenticated` otherwise.
 * Returns the v2 `AuthData` so callers can read `uid` / `token`.
 */
export function assertAuth(req: CallableRequest): AuthData {
  if (!req.auth) {
    throw new HttpsError("unauthenticated", "Sign-in required.");
  }
  return req.auth;
}

/**
 * Assert that the caller holds one of `roles`. Throws:
 *  - `unauthenticated` if no auth context.
 *  - `permission-denied` if the role is missing or not in the allow-list.
 *
 * Always call this BEFORE any side-effecting work in admin callables.
 */
export function assertRole(req: CallableRequest, roles: Role[]): AuthData {
  const authData = assertAuth(req);
  const role = extractRole(req.auth);
  if (!role || !roles.includes(role)) {
    throw new HttpsError(
      "permission-denied",
      `This action requires one of: ${roles.join(", ")}.`,
    );
  }
  return authData;
}

/** Convenience: caller must be admin. */
export function assertAdmin(req: CallableRequest): AuthData {
  return assertRole(req, ["admin"]);
}

/** True if the caller is the owner of `uid` OR an admin. */
export function isOwnerOrAdmin(req: CallableRequest, uid: string): boolean {
  if (!req.auth) return false;
  if (req.auth.uid === uid) return true;
  const role = extractRole(req.auth);
  return role === "admin";
}
