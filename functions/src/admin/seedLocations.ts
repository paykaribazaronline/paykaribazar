/**
 * Admin-only seeding endpoint — replaces the client-side `DatabaseSeeder`
 * which previously mutated Firestore on app launch (P0: client-driven DB
 * mutations on startup).
 *
 * Supports a `kind` parameter to scope what is seeded:
 *   - "locations"  → districts/upazilas/areas into settings/delivery_zones
 *   - "categories"  → default category tree
 *   - "ai_quota"    → seed the AI quota bucket per-user (or "global")
 *   - "all"         → run all of the above (default)
 *
 * Data is bundled inside the function for now (small enough to ship). When
 * it grows beyond ~1 MB it should move to a Storage-hosted JSON the function
 * streams.
 */
import { onCall } from "firebase-functions/v2/https";
import { db, assertAdmin, FieldValue } from "../admin";
import { recordAudit } from "../audit/auditLog";

type SeedKind = "locations" | "categories" | "ai_quota" | "all";

interface SeedInput {
  kind?: SeedKind;
  dryRun?: boolean;
}

const LOCATIONS = [
  {
    name: "Dhaka City",
    districts: ["Dhaka"],
    stations: ["Gulshan", "Dhanmondi", "Mirpur", "Uttara", "Mohammadpur"],
    areas: [],
    fee: 60,
  },
  {
    name: "Chattogram",
    districts: ["Chattogram"],
    stations: ["Agrabad", "GEC Circle", "Bahaddarhat"],
    areas: [],
    fee: 100,
  },
  {
    name: "Sylhet",
    districts: ["Sylhet"],
    stations: ["Zindabazar", "Upashahar"],
    areas: [],
    fee: 120,
  },
];

const CATEGORIES = [
  { id: "grocery", name: "Grocery", nameBn: "মুদি", icon: "🛒" },
  { id: "medicine", name: "Medicine", nameBn: "ওষুধ", icon: "💊" },
  { id: "electronics", name: "Electronics", nameBn: "ইলেকট্রনিক্স", icon: "🔌" },
  { id: "household", name: "Household", nameBn: "গৃহস্থালি", icon: "🏠" },
  { id: "personal-care", name: "Personal Care", nameBn: "ব্যক্তিগত যত্ন", icon: "🧴" },
];

export const runSeed = onCall(
  { region: "asia-southeast1", timeoutSeconds: 300, memory: "512MiB" },
  async (req) => {
    const caller = assertAdmin(req);
    const input = (req.data ?? {}) as Partial<SeedInput>;
    const kind: SeedKind =
      input.kind && ["locations", "categories", "ai_quota", "all"].includes(input.kind)
        ? input.kind
        : "all";
    const dryRun = Boolean(input.dryRun);

    const summary: Record<string, number> = {};

    if (!dryRun) {
      if (kind === "all" || kind === "locations") {
        const zonesRef = db.doc("settings/delivery_zones");
        await zonesRef.set(
          { zones: LOCATIONS, updatedAt: FieldValue.serverTimestamp() },
          { merge: true },
        );
        summary.locations = LOCATIONS.length;
      }
      if (kind === "all" || kind === "categories") {
        const batch = db.batch();
        for (const c of CATEGORIES) {
          batch.set(db.doc(`categories/${c.id}`), {
            ...c,
            updatedAt: FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
        summary.categories = CATEGORIES.length;
      }
      if (kind === "all" || kind === "ai_quota") {
        // Seed a global quota bucket the AI rate-limiter reads from.
        await db.doc("settings/ai_quota").set(
          {
            globalDailyLimit: 1000,
            perUserDailyLimit: 50,
            resetAt: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
        summary.ai_quota = 1;
      }
    } else {
      summary.dryRun = 1;
      summary.wouldSeed = (kind === "all" ? 3 : 1);
    }

    await recordAudit({
      actorUid: caller.uid,
      action: "admin.seed_run",
      targetType: "system",
      targetId: kind,
      after: summary,
      metadata: { dryRun },
    });

    return { kind, dryRun, summary };
  },
);

// Re-exported so a typed caller can import SeedInput if needed.
export type { SeedInput };
