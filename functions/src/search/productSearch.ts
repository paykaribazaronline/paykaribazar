/**
 * Server-side product search.
 *
 * Approach: read up to N (default 200) products from Firestore, filter
 * server-side on `name`, `nameBn`, `sku`, `brand`, `category`, `tags`,
 * plus a small synonym map for common Bangla→English transliteration.
 *
 * For >5k SKUs, switch to Algolia or Typesense and have a Cloud Function
 * sync `products/{id}` writes to a search index. The helper
 * `buildSearchTokens` is provided so the migration is one-step: every
 * product doc gets a denormalised `searchTokens: string[]` field that the
 * index can ingest.
 */
import { onCall } from "firebase-functions/v2/https";
import { db, assertAuth } from "../admin";
import { errInvalidArgument } from "../shared/security";

// A tiny synonym map — extend as needed. Keys are normalised lowercase.
const SYNONYMS: Record<string, string[]> = {
  chal: ["rice"],
  rice: ["chal"],
  tel: ["oil"],
  oil: ["tel"],
  dim: ["egg"],
  egg: ["dim"],
  chini: ["sugar"],
  sugar: ["chini"],
  lobongola: ["lentil", "dal"],
  dal: ["lentil", "lobongola"],
};

export interface SearchProductsInput {
  query: string;
  limit?: number; // default 50, max 200
  category?: string;
  brand?: string;
  minStock?: number;
}

export interface SearchHit {
  id: string;
  name: string;
  nameBn: string;
  sku: string;
  brand: string;
  category: string;
  imageUrl: string;
  price: number;
  stock: number;
  score: number;
}

export const searchProducts = onCall(
  { region: "asia-southeast1" },
  async (req) => {
    assertAuth(req);
    const input = (req.data ?? {}) as Partial<SearchProductsInput>;
    const query = (input.query ?? "").toString().trim();
    const limit = Math.min(Math.max(Number(input.limit ?? 50), 1), 200);
    if (!query) {
      errInvalidArgument("query is required.");
    }

    // Build the list of terms we will match against (original + synonyms).
    const tokens = query
      .toLowerCase()
      .split(/[\s,]+/)
      .filter(Boolean)
      .flatMap((t) => [t, ...(SYNONYMS[t] ?? [])]);
    const tokenSet = Array.from(new Set(tokens));

    // Scan products in batches — capped to keep memory predictable.
    const scanLimit = 500;
    let snapshot = await db
      .collection("products")
      .limit(scanLimit)
      .get();

    const hits: SearchHit[] = [];
    for (const doc of snapshot.docs) {
      const p = doc.data() as Record<string, unknown>;
      if (input.category && String(p.categoryId ?? "") !== input.category) continue;
      if (input.brand && String(p.brand ?? "") !== input.brand) continue;
      const stock = Number(p.stock ?? 0);
      if (typeof input.minStock === "number" && stock < input.minStock) continue;

      const haystack = [
        String(p.name ?? ""),
        String(p.nameBn ?? ""),
        String(p.sku ?? ""),
        String(p.brand ?? ""),
        String(p.categoryName ?? ""),
        String(p.categoryNameBn ?? ""),
        ...((p.tags ?? []) as string[]),
        ...((p.aiTags ?? []) as string[]),
      ]
        .join(" ")
        .toLowerCase();

      let score = 0;
      for (const t of tokenSet) {
        if (haystack.includes(t)) score += 1;
      }
      if (score === 0) continue;

      hits.push({
        id: doc.id,
        name: String(p.name ?? ""),
        nameBn: String(p.nameBn ?? ""),
        sku: String(p.sku ?? ""),
        brand: String(p.brand ?? ""),
        category: String(p.categoryName ?? ""),
        imageUrl: String(p.imageUrl ?? ""),
        price: Number(p.price ?? 0),
        stock,
        score,
      });
    }

    hits.sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));
    return { query, hits: hits.slice(0, limit), scanned: snapshot.size };
  },
);

/**
 * Build a denormalised `searchTokens` array for a product doc. Used by an
 * admin / migration script to populate the field so a future Algolia /
 * Typesense index can ingest it without re-scanning source data.
 */
export function buildSearchTokens(product: Record<string, unknown>): string[] {
  const tags = (product.tags ?? []) as string[];
  const aiTags = (product.aiTags ?? []) as string[];
  const raw = [
    String(product.name ?? ""),
    String(product.nameBn ?? ""),
    String(product.sku ?? ""),
    String(product.brand ?? ""),
    String(product.categoryName ?? ""),
    String(product.categoryNameBn ?? ""),
    ...tags,
    ...aiTags,
  ];
  const tokens = new Set<string>();
  for (const r of raw) {
    for (const t of r.toLowerCase().split(/[\s,]+/)) {
      if (t) {
        tokens.add(t);
        for (const syn of SYNONYMS[t] ?? []) tokens.add(syn);
      }
    }
  }
  return Array.from(tokens).sort();
}
