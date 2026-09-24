/**
 * Audit log helper. Every privileged mutation in this backend should call
 * `recordAudit` to leave a server-timestamped, tamper-evident trail in
 * `auditLogs/{logId}`. Firestore rules MUST make `auditLogs` write-only for
 * non-admins (admin can read, everyone can append via this function only).
 */
import { db, FieldValue, Timestamp } from "../admin";

export interface AuditEntry {
  actorUid: string | null;
  action: string;
  targetType:
    | "user"
    | "order"
    | "payment"
    | "reservation"
    | "coupon"
    | "product"
    | "prescription"
    | "system"
    | string;
  targetId: string;
  before?: unknown;
  after?: unknown;
  metadata?: Record<string, unknown>;
}

export async function recordAudit(entry: AuditEntry): Promise<string> {
  const docRef = db.collection("auditLogs").doc();
  await docRef.set({
    id: docRef.id,
    actorUid: entry.actorUid,
    action: entry.action,
    targetType: entry.targetType,
    targetId: entry.targetId,
    before: entry.before ?? null,
    after: entry.after ?? null,
    metadata: entry.metadata ?? {},
    at: FieldValue.serverTimestamp(),
    // `at` resolves server-side; include an explicit Timestamp so queries that
    // sort by `at` work even before the server value is materialised.
    clientTime: Timestamp.now(),
  });
  return docRef.id;
}
