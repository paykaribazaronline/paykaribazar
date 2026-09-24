# Security

This document is the canonical security reference for Paykari Bazar. It covers:

1. Threat model
2. Trust boundary
3. Secret management
4. Custom claims and roles
5. App Check
6. Firestore rules summary
7. Storage rules summary
8. Audit logging
9. Incident response
10. Responsible disclosure policy

For the architecture and trust boundary diagram see [`ARCHITECTURE.md`](./ARCHITECTURE.md). For payment-specific security see [`PAYMENTS.md`](./PAYMENTS.md). For incident handling runbooks see [`RUNBOOK.md`](./RUNBOOK.md).

---

## 1. Threat model

### Assets

- **Customer PII**: name, phone, address, order history
- **Business data**: trade license, credit limit, business tier
- **Money**: wallet balance, loyalty points, payments ledger
- **Inventory**: stock counts, reservation ledger, pricing (wholesale + tiered)
- **Authorization**: custom claims (role, admin, staff flags)
- **Healthcare data**: prescription images, OCR text (separate security domain)
- **API keys**: Gemini AI, bKash/Nagad/SSLCommerz merchant credentials

### Adversaries

- **Curious customer** — tries to read another customer's orders, wallet, transactions
- **Malicious reseller** — tries to write `wholesalePrice`, `stock`, `tieredPrices` on their own products to undercut the platform
- **Compromised client** — a modified APK that bypasses the Flutter UI to call Firestore directly
- **Replay attacker** — captures a payment redirect URL and tries to replay it
- **Webhook spoofer** — sends a fake `bkashWebhook` HTTP request to mark an unpaid order as paid
- **Credential stuffer** — tries email/password lists against Auth
- **Insider threat** — a staff member who tries to read another staff member's audit log entries or escalate to admin

### Mitigations (per-asset)

| Asset                | Threat                                  | Mitigation |
| -------------------- | --------------------------------------- | ---------- |
| Customer PII         | cross-customer read                     | `users/{uid}` read = owner-or-staff; subcollections owner-only |
| Money                | client-side mutation                    | `walletBalance`, `points`, `transactions/{txId}` are server-only; mutations via signed callables |
| Inventory            | client-side `stock = newStock`          | `products.stock`, `reservedStock`, `soldStock` are server-only; mutations via `reserveStock`/`commitReservation` |
| Pricing              | client-side `wholesalePrice` undercut   | pricing moved to `productPrices/{productId}` (server-only); `calcOrder` HMAC-signs the snapshot |
| Authorization        | role inference from email string        | role from custom claims only (set by `provisionStaff`/`setUserRole`); `firestore.rules` reads `request.auth.token.role` first |
| Healthcare           | prescription leak                       | distinct `prescriptions/{id}` collection + `prescriptions/` Storage bucket; staff-only AI analysis (Gemini on the server, never on client) |
| API keys             | key extraction from APK                 | no keys in client binary; AI runs server-side via `analyzePrescription` callable; `secrets_service.dart` is `@Deprecated` |
| Payments             | webhook spoofing, replay                | webhooks re-query gateway before writing `payments/{id}`; client polls `verifyPayment` (idempotent Firestore writes); order marked paid only after BOTH agree |
| Audit logs           | tampering                               | `auditLogs/{id}` is append-only (create-only, no update/delete) |
| Auth                 | credential stuffing                     | Firebase Auth rate limiting + App Check; password reset throttled |

---

## 2. Trust boundary

The trust boundary is the Cloud Functions layer. **The client is fully untrusted.** Every money / inventory / payment / role / authorization decision is re-verified server-side.

See [`ARCHITECTURE.md` § 1](./ARCHITECTURE.md#1-trust-boundary) for the diagram and the 5 rules.

The practical implication: if you find yourself writing Firestore `.set()` / `.update()` from the client for any of these collections — `orders`, `payments`, `inventoryReservations`, `users/{uid}/transactions`, `auditLogs`, `hub/data/productPrices`, the inventory/pricing keys on `products` — **stop**. Route through a Callable Cloud Function.

---

## 3. Secret management

### Policy

1. **No secrets in the client binary.** The Flutter APK is trivially decompilable. Any key shipped in `lib/` will leak.
2. **No secrets in `.env` checked in.** `.env` is git-ignored. `.env.example` may be checked in but contains only placeholders. CI verifies this (`.github/workflows/security.yml` → `env-example-check`).
3. **No long-lived service account JSON in CI.** Production deploys use **Workload Identity Federation** (`google-github-actions/auth@v2`) — no `service-account-*.json` file in GitHub Secrets.
4. **Backend secrets live in Google Secret Manager.** Cloud Functions read them via `process.env` (set by `firebase functions:config` or Secret Manager). The local emulator loads them from `functions/.env` (git-ignored).
5. **Rotation**: every 90 days for payment gateway credentials; every 30 days for the `PRICING_HMAC_SECRET`; immediately on staff turnover.

### Backend secrets (see `functions/.env.example`)

```
# bKash
BKASH_APP_KEY=
BKASH_APP_SECRET=
BKASH_USERNAME=
BKASH_PASSWORD=
BKASH_BASE_URL=https://tokenized.sandbox.bka.sh/v1.2.0-beta
BKASH_CALLBACK_URL=https://asia-southeast1-paykari-prod.cloudfunctions.net/bkashWebhook

# Nagad
NAGAD_MERCHANT_ID=
NAGAD_PUBLIC_KEY=
NAGAD_PRIVATE_KEY=
NAGAD_CALLBACK_URL=https://asia-southeast1-paykari-prod.cloudfunctions.net/nagadWebhook

# SSLCommerz
SSLCOMMERZ_STORE_ID=
SSLCOMMERZ_STORE_PASSWD=
SSLCOMMERZ_BASE_URL=https://sandbox.sslcommerz.com/gwprocess/v4/api.php

# Bank transfer
BANK_ACCOUNTS_JSON=[{"bank":"Dutch-Bangla Bank","accountName":"Paykari Bazar Ltd","accountNumber":"123456789012","branch":"Dhanmondi"}]

# AI (server-side only)
GEMINI_API_KEY=

# Pricing signature
PRICING_HMAC_SECRET=

# Ops
SLACK_WEBHOOK_URL=
SENTRY_DSN_FUNCTIONS=
```

### GitHub Actions secrets

| Secret                          | Purpose |
| ------------------------------- | ------- |
| `FIREBASE_TOKEN`                | Firebase CLI deploy token (per-env) |
| `FIREBASE_PROJECT_ID`           | Firebase project ID (per-env) |
| `GCP_FUNCTIONS_WIF_PROVIDER`   | Workload Identity Federation provider resource name |
| `GCP_FUNCTIONS_SERVICE_ACCOUNT`| Service account impersonated by WIF |
| `KEYSTORE_BASE64`               | Android release keystore (base64) |
| `KEYSTORE_PROPERTIES_B64`       | `keystore.properties` (base64) |
| `SHOREBIRD_AUTH_TOKEN`           | Shorebird release API token |
| `SLACK_WEBHOOK`                  | Slack incoming webhook for CI notifications |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Play Console service account (legacy — will migrate to WIF) |

### Verification

CI enforces secret hygiene on every PR:

- `trufflehog` scans full history for verified secret patterns (FATAL)
- `gitleaks` complements trufflehog (FATAL)
- `trivy` filesystem scan (FATAL on CRITICAL/HIGH CVEs)
- `forbidden-secret-patterns` job fails if any of the previously-leaked placeholder secrets reappear:
  - `paykari_bazar_api_key`
  - `paykari_bazar_api_secret_key_1234567890`
  - `MySecureAES256KeyFor32BytLength!`
  - `0123456789.0123456789.0123456789`
- `env-example-check` job fails if `.env.example` has any non-placeholder secret

### Rotation procedure

1. Generate new secret in Google Secret Manager.
2. Update Cloud Functions env config: `firebase functions:config:set ...` or `firebase functions:secrets:set ...`.
3. Redeploy affected functions (callables first, webhooks second, triggers third).
4. Verify in staging (sandbox gateway) before rotating production.
5. Revoke the old secret at the gateway's dashboard.
6. Update `SLACK_WEBHOOK_URL` to broadcast the rotation to the ops channel.
7. File an entry in `docs/CHANGELOG-PRODUCTION-PATCH.md` under "Security rotations".

---

## 4. Custom claims and roles

### Role taxonomy

| Role      | Claim value | Capabilities |
| --------- | ----------- | ------------ |
| customer  | `customer`  | browse, cart, place orders, pay, write own profile, write own address, write own wishlist |
| reseller  | `reseller`  | customer + create `businesses/{id}`, write product merchandising fields (NOT pricing/stock), view `inventoryReservations` |
| staff     | `staff`     | reseller + read any `orders`, `payments`, `users`, `businesses`; update order `status`; update `prescriptions`; assign riders (via future callable) |
| rider     | `rider`     | read assigned `orders`; update `orders.{orderId}.status` to `dispatched`/`delivered` (via future `assignRider` callable) |
| admin     | `admin`     | staff + delete orders, manage coupons, manage product prices, manage inventory, provision staff, view `auditLogs` |

### Claims structure

```json
{
  "role": "staff",
  "admin": false,
  "staff": true,
  "reseller": false,
  "rider": false,
  "businessId": "biz_xyz"
}
```

`firestore.rules` prefer the boolean flags (`request.auth.token.admin == true`) for performance (no extra `get()`); `request.auth.token.role` is the secondary check.

### Provisioning

Roles are provisioned exclusively via:

- **`onUserCreate` trigger** — sets `role: 'customer'` on signup
- **`provisionStaff` callable** — admin onboards a staff member (sets `role: 'staff'` claim + `users/{uid}.role` doc field atomically)
- **`setUserRole` callable** — admin escalates/de-escalates any user's role (writes both claim and doc; cannot self-escalate)
- **`provisionRole` callable** — lower-level primitive used by the above

The client NEVER sets its own role. The original code's `email.startsWith('admin')` inference is GONE.

---

## 5. App Check

Firebase App Check is enforced on:

- **Cloud Functions** (callable + HTTP) — `assertAppCheck()` helper in `functions/src/shared/security.ts`
- **Firestore** — App Check enforcement is enabled in the Firebase Console (rules still apply as defense-in-depth)
- **Cloud Storage** — same

In development, the App Check debug token is registered via `firebase appcheck:debug:new-token` and passed to the client. In production, the Play Integrity provider is enforced.

App Check does NOT replace Firebase Auth — it only attests that the request originates from a genuine app build. Every callable still verifies the Auth context (`context.auth.uid`) and the custom claims.

---

## 6. Firestore rules summary

`firestore.rules` is `rules_version = '2';` with the following helper functions:

- `isAuth()` — `request.auth != null`
- `isOwner(uid)` — `isAuth && request.auth.uid == uid`
- `isAdmin()` — prefers `request.auth.token.admin == true`
- `isStaff()` — prefers `request.auth.token.role in ['admin', 'staff']`
- `isReseller()` — `request.auth.token.role == 'reseller' || request.auth.token.reseller == true`
- `isRider()` — `request.auth.token.role == 'rider' || request.auth.token.rider == true`

### Per-collection summary

| Collection                                | Read                       | Create            | Update                                | Delete          |
| ----------------------------------------- | -------------------------- | ----------------- | ------------------------------------- | --------------- |
| `users/{uid}`                             | owner-or-staff             | owner (server-only fields blocked) | self-update OR staff operational update (no self-escalation) | admin |
| `users/{uid}/addresses`                   | owner                      | owner             | owner                                 | owner           |
| `users/{uid}/wishlist`                    | owner                      | owner             | owner                                 | owner           |
| `users/{uid}/transactions/{txId}`         | owner                      | **false** (server-only) | **false**                        | **false**       |
| `businesses/{id}`                         | authed                     | owner             | owner-or-staff                        | admin           |
| `hub/data/products/{id}`                  | `true`                     | admin-or-reseller (server-only keys blocked) | admin-or-reseller (server-only keys blocked) | admin |
| `hub/data/productPrices/{id}`             | `true`                     | admin             | admin                                 | admin           |
| `inventoryReservations/{id}`              | owner-or-staff             | **false**         | **false**                             | **false**       |
| `orders/{id}`                             | owner-or-staff-or-rider    | **false** (server-only via `createOrder`) | staff OR customer self-cancel `['status','updatedAt']` only | admin |
| `payments/{id}`                            | owner-or-staff             | **false**         | **false**                             | **false**       |
| `auditLogs/{id}`                          | admin                      | isAuth (callable) | **false**                             | **false**       |
| `settings/coupons/{id}`                   | `true`                     | admin             | admin                                 | admin           |
| `prescriptions/{id}`                      | owner-or-staff             | owner             | staff                                 | admin           |
| `private_chats/{id}` + `messages`         | participants only          | participants      | participants                          | admin           |
| default `/{document=**}`                  | **false**                  | **false**         | **false**                             | **false**       |

Every collection in the original rules (categories, stores, donors, doctors, helplines, notifications, ai_audit_logs, commissions, staff_commissions, expenses, promos, hero_records, rateLimits, ai_sovereign_rules, notices, password_reset_requests, applications, monthly_stats, analytics, ai_notifications_queue, api_quota, settings, notes, user_media, _system/admin, _system/billing, localization) is preserved with tightened rules — full text in `firestore.rules`.

### Bootstrap holes closed

The original rules had two bootstrap holes that allowed writes if a document didn't exist yet:

- `hub/data/locations` write was allowed if `!exists(.../dhaka)` — now `isAdmin()` only
- `settings/{docId}` write was allowed if `!exists(.../api_quota)` — now `isAdmin()` only

Both are closed.

### Rules testing

Every change to `firestore.rules` or `storage.rules` MUST be accompanied by a test under `test/firestore_rules/`. CI runs `firebase emulators:exec --only firestore,storage "dart test test/firestore_rules/"` on every PR (see `.github/workflows/rules-emulator-test.yml`).

---

## 7. Storage rules summary

`storage.rules` mirrors the Firestore role logic. Paths:

| Path                                  | Read                          | Write                  | Max size | MIME |
| ------------------------------------- | ----------------------------- | ---------------------- | -------- | ---- |
| `profile_photos/{uid}/**`             | public                        | owner                  | 5MB      | `image/.*` |
| `products/{productId}/**`             | public                        | admin-or-reseller      | 10MB     | `image/.*` |
| `prescriptions/{userId}/**`           | owner-or-staff                | owner                  | 5MB      | `image/(jpeg\|png\|webp)` |
| `paymentslips/{userId}/{paymentId}`   | owner-or-staff                | owner                  | 8MB      | `image/(jpeg\|png\|webp)` |
| `chat_attachments/{chatId}/**`        | participants (via Firestore `private_chats/{chatId}.participantIds`) | participants | 10MB | `image/.*\|application/pdf` |
| `medical_documents/{userId}/**`       | owner-or-staff                | owner                  | 5MB      | `image/(jpeg\|png\|webp)\|application/pdf` |
| `backups/**`                          | admin                         | **false**              | —        | —    |
| default `/**`                         | **false**                     | **false**              | —        | —    |

---

## 8. Audit logging

Every privileged server action writes to `auditLogs/{logId}` BEFORE returning to the client. The schema:

```typescript
{
  actorUid: string,        // who did it
  actorRole: string,       // 'admin' | 'staff' | 'reseller' | 'system'
  action: string,          // 'ORDER_STATUS_CHANGE' | 'PAYMENT_REFUND' | 'ROLE_PROVISION' | ...
  targetCollection: string,
  targetId: string,
  before: { ... },         // prior state
  after: { ... },          // new state
  ipAddress: string|null,  // from callable context
  userAgent: string|null,
  timestamp: Timestamp,    // server-only via FieldValue.serverTimestamp()
}
```

Rules: append-only (create by callable context, no update/delete). Read = admin only.

The `auditLog` helper in `functions/src/audit/auditLog.ts` writes the log and re-tries on transient Firestore errors.

### What is audited

- Order status changes (by staff or system)
- Payment refunds
- Role provisioning (`provisionStaff`, `setUserRole`)
- Stock adjustments (manual or system reconciliation)
- Coupon CRUD
- Firestore/Storage rules deploy
- AI enrichment runs (`smartEnrichProduct` → `ai_audit_logs`)

---

## 9. Incident response

### Severity matrix

| Severity | Definition                                          | Response time |
| -------- | --------------------------------------------------- | ------------- |
| SEV-1    | Money loss / data breach / production down          | immediate     |
| SEV-2    | Partial outage / no money loss / workaround exists  | < 1 hour      |
| SEV-3    | Bug, no outage, no money loss                        | next business day |
| SEV-4    | Cosmetic, documentation                              | backlog |

### Process

1. **Detect** — Sentry alert, customer report, Slack ping, Cloud Monitoring alert.
2. **Triage** — on-call engineer confirms SEV level, opens a Slack thread `#incidents`.
3. **Mitigate** — apply the runbook fix from [`RUNBOOK.md`](./RUNBOOK.md). If no runbook exists, document the fix as you go.
4. **Communicate** — SEV-1/SEV-2 require a status update to `#incidents` every 30 min until resolved.
5. **Resolve** — confirm fix in production, close the alert.
6. **Post-mortem** — for SEV-1/SEV-2: a blameless post-mortem within 48 hours, filed under `docs/postmortems/`. Add the new runbook to [`RUNBOOK.md`](./RUNBOOK.md) if missing.

### Rollback

- **Cloud Functions**: each release creates a Firebase function version. Roll back via `firebase functions:rollback` or by re-deploying the previous git SHA.
- **Firestore rules**: rollback via `firebase deploy --only firestore:rules` from the previous git SHA. Rules versions are atomic; a deploy either fully succeeds or fully fails.
- **Flutter app**: rollback via Shorebird patch (instant) or Play Store rollback (slow).

---

## 10. Responsible disclosure policy

We welcome security researchers to report vulnerabilities responsibly.

- **Email**: `security@paykaribazar.com` (encrypted with our PGP key, available on request)
- **Scope**: production Firebase project, production Cloud Functions, production Flutter app, this GitHub repository.
- **Out of scope**: sandbox/staging projects, brute-force, DoS, social engineering of staff.
- **Reward**: acknowledgment in `docs/CHANGELOG-PRODUCTION-PATCH.md` and (for high-impact findings) a bug bounty.
- **Timeline**: we acknowledge within 48 hours, validate within 7 days, patch within 30 days (or 90 days for low-severity), and disclose publicly after the patch is deployed.
- **Do NOT**: access or modify other users' data, exploit the issue beyond a proof-of-concept, or disclose the issue publicly before we have shipped a fix.

---

## Appendix A: Known mitigations of historical issues

This patch fixes the following P0/P1 issues (cross-reference: `docs/CHANGELOG-PRODUCTION-PATCH.md`):

| Issue | Mitigation |
| ----- | ---------- |
| Payment placeholder `return true` | Replaced with real bKash/Nagad/SSL/Bank client + backend verifyPayment callable |
| Client-side money calculation | All totals come from server-signed PricingSnapshot; OrderService.placeOrder delegates to calcOrder+reserveStock+createOrder |
| Inventory race condition (`stock = newStock`) | reserveStock uses Firestore transaction; atomic decrement/increment on stock/reservedStock |
| Firestore rules too permissive | Rewritten with role-based helpers, server-only fields, default-deny |
| Role inferred from email string | Roles from custom claims only (set by provisionStaff/setUserRole callables) |
| Client-side secrets (`.env` in assets, SecretsService, security_initializer hardcoded fallbacks) | `.env` git-ignored; `secrets_service.dart` `@Deprecated`; `security_initializer.dart` throws in release mode; AI runs server-side via callable |
| Auth signup bug (`Future.wait([settingsFuture])` then `results[1]`) | Replaced with `final settingsSnap = await settingsFuture;` |
| Admin startup seeding (DB mutations on app launch) | Seeding block removed from `lib/main_admin.dart`; seeding now via `seedLocations` callable |
| Android release signing fallback to debug | build.gradle fail-fasts with `throw new GradleException(...)` if production keystore is missing |
| CI/CD `continue-on-error` everywhere | All `continue-on-error` removed; analyze is fatal; rules/functions tests added |
| `firebase_performance: any`, platform interface deps as `any` | All deps pinned in `pubspec.yaml` |
| README insufficient; duplicate project dirs | README rewritten; `paykari_bazar/` and `paykari_bazar_admin/` marked as legacy |
| Search not scalable (client-side filter) | New `searchProducts` callable (server-side); client `searchProducts` stream `@Deprecated` |
| AI feature not "real" (`smartEnrichProduct` ignores imageBytes; latency hard-coded) | `smartEnrichProduct` now passes imageBytes to Gemini vision; `performGlobalSystemCheck` measures real latency with Stopwatch |
| Prescription/healthcare not isolated | Distinct `prescriptions/{id}` collection + `prescriptions/` Storage bucket with strict rules |
| Product data provenance (chaldal.csv etc.) | Documented in `docs/DATA_PROVENANCE.md`; cannot launch commercially without self-owned catalog |
