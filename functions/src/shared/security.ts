/**
 * Shared low-level helpers:
 *  - HMAC sign / verify for pricing snapshots (the trust anchor between
 *    calcOrder → reserveStock → createOrder).
 *  - Integer poisha money math (1 taka = 100 poisha) — never floats.
 *  - Canonical JSON so snapshots are byte-stable across calls.
 *  - Typed HttpsError factories so the Flutter client gets consistent codes.
 */
import * as crypto from "crypto";
import { https } from "firebase-functions";

const HMAC_SECRET = process.env.WEBHOOK_HMAC_SECRET ?? "";
if (!HMAC_SECRET) {
  // We deliberately do NOT throw at module load (breaks emulator cold start).
  // Every sign/verify call re-reads the env and throws a precise error if it
  // is still missing at request time.
  // eslint-disable-next-line no-console
  console.warn(
    "[security] WEBHOOK_HMAC_SECRET is not set — pricing snapshots will fail.",
  );
}

/** Stable key ordering so the same logical payload always produces the same HMAC. */
export function canonicalJson(obj: unknown): string {
  return JSON.stringify(sortKeys(obj));
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    const keys = Object.keys(value as Record<string, unknown>).sort();
    for (const k of keys) {
      out[k] = sortKeys((value as Record<string, unknown>)[k]);
    }
    return out;
  }
  return value;
}

/**
 * Compute an HMAC-SHA256 over the canonical JSON of `payload`, prefixed with
 * the schema version so future format changes can be rolled out safely.
 */
export function signSnapshot(payload: unknown, version = "v1"): string {
  if (!HMAC_SECRET) {
    throw new https.HttpsError(
      "failed-precondition",
      "Server missing HMAC secret — pricing snapshots unavailable.",
    );
  }
  const body = `${version}.${canonicalJson(payload)}`;
  const sig = crypto
    .createHmac("sha256", HMAC_SECRET)
    .update(body, "utf8")
    .digest("hex");
  return `${version}.${sig}`;
}

/** Verify a previously produced signature. Returns the canonical body for inspection. */
export function verifySnapshot(payload: unknown, signature: string): boolean {
  if (!HMAC_SECRET) {
    throw new https.HttpsError(
      "failed-precondition",
      "Server missing HMAC secret — cannot verify snapshot.",
    );
  }
  const dot = signature.indexOf(".");
  if (dot < 0) return false;
  const version = signature.slice(0, dot);
  const expected = signSnapshot(payload, version);
  // Timing-safe comparison.
  const a = Buffer.from(expected);
  const b = Buffer.from(signature);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

// ---------------------------- money math -----------------------------------

/** 1 taka = 100 poisha. All internal arithmetic is in integer poisha. */
export const POISHA_PER_TAKA = 100;

/** Convert a taka amount (possibly a float from JSON) to integer poisha. */
export function takaToPoisha(taka: number): number {
  if (!Number.isFinite(taka)) {
    throw new https.HttpsError("invalid-argument", `Non-finite money value: ${taka}`);
  }
  return Math.round(taka * POISHA_PER_TAKA);
}

/** Convert integer poisha back to taka for API output. */
export function poishaToTaka(poisha: number): number {
  return Math.round(poisha) / POISHA_PER_TAKA;
}

// ---------------------------- typed errors ---------------------------------

export function errInvalidArgument(message: string, details?: unknown): never {
  throw new https.HttpsError("invalid-argument", message, details);
}

export function errPermissionDenied(message: string, details?: unknown): never {
  throw new https.HttpsError("permission-denied", message, details);
}

export function errFailedPrecondition(message: string, details?: unknown): never {
  throw new https.HttpsError("failed-precondition", message, details);
}

export function errNotFound(message: string, details?: unknown): never {
  throw new https.HttpsError("not-found", message, details);
}

export function errInternal(message: string, details?: unknown): never {
  throw new https.HttpsError("internal", message, details);
}

// ---------------------------- misc -----------------------------------------

/** 10-minute window during which a pricing snapshot is acceptable. */
export const PRICING_TTL_MS = 10 * 60 * 1000;
/** 15-minute window during which a reservation is held before auto-release. */
export const RESERVATION_TTL_MS = 15 * 60 * 1000;

export function nowMs(): number {
  return Date.now();
}
