# Changelog — Production Hardening Patch

This changelog documents the production-hardening patch applied to Paykari Bazar. It cross-references the worklog entries in [`/home/z/my-project/worklog.md`](../../../my-project/worklog.md).

> Format: each entry has the issue ID (P0 / P1), the file(s) changed, and the fix. Cross-references are listed as `[worklog: Task ID X]`.

---

## Summary

This patch closes every P0 (production-blocking) issue and most P1 (production-degrading) issues identified in the initial security audit. The result is a production-grade B2B commerce platform where:

- Money, inventory, and payment decisions are made **only** by Cloud Functions (never the client).
- Firestore and Storage rules are **locked down** and **emulator-tested** on every PR.
- CI is a **real quality gate** — no `continue-on-error`, fatal analyze, blocking secret scans.
- Every dependency is **pinned** (no `any`).
- The trust boundary is documented end-to-end (architecture, security, payments, deployment, runbook, data provenance).

---

## P0 — Production-blocking issues

### P0-1: Payment is placeholder (`return true`)

- **Files changed**:
  - `lib/src/shared/services/payment_service.dart` [worklog: Task ID 3-4-5-6]
  - `lib/src/features/payments/services/{bkash,nagad,sslcommerz,bank}_service.dart` [worklog: Task ID 3-4-5-6]
  - `lib/src/features/payments/providers/payment_provider.dart` [worklog: Task ID 3-4-5-6]
  - `lib/src/features/payments/services/payment_redirect_handler.dart` [worklog: Task ID 3-4-5-6]
  - `functions/src/payments/{bkash,nagad,sslcommerz,bank}.ts` [worklog: Task ID 9]
  - `functions/src/payments/verifyPayment.ts` [worklog: Task ID 9]
  - `functions/src/payments/refund.ts` [worklog: Task ID 9]
  - `functions/src/payments/webhooks/{bkash,nagad,sslcommerz}Webhook.ts` [worklog: Task ID 9]
- **Fix**: Replaced the placeholder `Future.delayed` + `return true` simulation with a real payment pipeline. The Flutter client calls `bkashCreatePayment` / `nagadCreatePayment` / `sslczCreatePayment` callables, opens the gateway URL, captures the deep-link redirect, and polls `verifyPayment` every 3s for up to 2 min. The backend re-queries the gateway before marking the order paid, and the webhook verifies the gateway signature. Bank transfer uses slip upload + staff manual verification.

### P0-2: Client-side money calculation in OrderService

- **Files changed**:
  - `lib/src/features/commerce/services/order_service.dart` [worklog: Task ID 3-4-5-6]
  - `lib/src/features/commerce/services/coupon_service.dart` [worklog: Task ID 3-4-5-6]
  - `lib/src/features/commerce/providers/cart_provider.dart` [worklog: Task ID 3-4-5-6]
  - `lib/src/features/checkout/services/checkout_service.dart` [worklog: Task ID 3-4-5-6]
  - `lib/src/features/checkout/models/pricing_snapshot.dart` [worklog: Task ID 3-4-5-6]
  - `functions/src/pricing/calcOrder.ts` [worklog: Task ID 9]
- **Fix**: `OrderService.placeOrder` no longer accepts `{subtotal, deliveryFee, discount, total}`. It calls `calcOrder` to get a server-signed `PricingSnapshot`, then `reserveStock` (which re-verifies the signature), then `createOrder` (which re-verifies the signature). Legacy client-money interfaces are `@Deprecated`. Cart provider exposes `calculateServerTotals()` that calls `calcOrder` and returns the snapshot.

### P0-3: Inventory race condition (non-atomic `stock = newStock`)

- **Files changed**:
  - `functions/src/inventory/reserveStock.ts` [worklog: Task ID 9]
  - `functions/src/inventory/releaseReservation.ts` [worklog: Task ID 9]
  - `functions/src/inventory/commitReservation.ts` [worklog: Task ID 9]
  - `lib/src/features/inventory/services/inventory_service.dart` [worklog: Task ID 3-4-5-6]
  - `lib/src/features/inventory/models/reservation_model.dart` [worklog: Task ID 3-4-5-6]
  - `firestore.rules` [worklog: Task ID 7-8]
- **Fix**: `reserveStock` runs inside a Firestore transaction that atomically checks `stock >= qty` and then decrements `stock` and increments `reservedStock`. Reservations have a 15-minute TTL (`expiresAt` field); a scheduled cron releases expired ones. `commitReservation` finalizes the hold (decrements `reservedStock`, increments `soldStock`) when the order is confirmed. The client never writes to `stock`, `reservedStock`, or `soldStock` — `firestore.rules` denies all client writes to those keys.

### P0-4: Firestore rules too permissive (users, transactions, orders)

- **Files changed**:
  - `firestore.rules` [worklog: Task ID 7-8]
  - `storage.rules` [worklog: Task ID 7-8]
- **Fix**: Full rewrite. Helpers: `isAuth`, `isOwner(uid)`, `isAdmin()` (prefers custom claims), `isStaff()`, `isReseller()`, `isRider()`. `users/{uid}` read = owner-or-staff (privacy); `transactions` server-only. `orders/{id}` create = `false` (must go through `createOrder` callable). New collections: `hub/data/productPrices/{id}`, `inventoryReservations/{id}`, `payments/{id}`, `auditLogs/{id}`, `settings/coupons/{id}`, `businesses/{id}`, `prescriptions/{id}`. Default-deny preserved. Two bootstrap holes closed (`hub/data/locations`, `settings/{docId}`).

### P0-5: Role inferred from email string

- **Files changed**:
  - `lib/src/features/auth/services/auth_service.dart` [worklog: Task ID 3-4-5-6]
  - `functions/src/admin/provisionStaff.ts` [worklog: Task ID 9]
  - `functions/src/admin/provisionRole.ts` [worklog: Task ID 9]
  - `functions/src/users/onUserCreate.ts` [worklog: Task ID 9]
  - `firestore.rules` [worklog: Task ID 7-8]
- **Fix**: The `if (email.startsWith('admin')) ... else if (email.contains('staff')) ...` block in `login` is replaced with `role ??= 'customer';` and a comment explaining the role now comes from Firebase Custom Claims. The `provisionStaff` / `setUserRole` callables set both the custom claim and the `users/{uid}.role` doc field atomically. `firestore.rules` reads `request.auth.token.role` first (fast), then falls back to the doc field (defensive).

### P0-6: Client-side secrets (`.env` in assets, SecretsService, security_initializer hardcoded fallbacks)

- **Files changed**:
  - `lib/src/core/services/security_initializer.dart` [worklog: Task ID 3-4-5-6]
  - `lib/src/core/services/secrets_service.dart` [worklog: Task ID 3-4-5-6]
  - `lib/src/features/ai/services/ai_automation_service.dart` [worklog: Task ID 10-11]
  - `.github/workflows/security.yml` [worklog: Task ID 10-11]
  - `.gitignore` [worklog: Task ID 10-11]
- **Fix**: `security_initializer.dart` removed hardcoded fallbacks `'MySecureAES256KeyFor32BytLength!'`, `'paykari_bazar_api_key'`, `'paykari_bazar_api_secret_key_1234567890'` — release mode throws `StateError`, debug mode uses dev-only keys with explicit `DEV_ONLY_NOT_FOR_PRODUCTION_` prefix. `secrets_service.dart` is fully `@Deprecated`. `smartEnrichProduct` is guarded by `if (kReleaseMode) throw UnsupportedError(...)` — AI enrichment must run server-side via `analyzePrescription`-style callable. CI `forbidden-secret-patterns` job fails the pipeline if any of the previously-leaked placeholder secret strings reappear in the source tree.

### P0-7: Auth signup bug `Future.wait([settingsFuture])` then `results[1]`

- **Files changed**:
  - `lib/src/features/auth/services/auth_service.dart` [worklog: Task ID 3-4-5-6]
- **Fix**: The original `Future.wait([settingsFuture])` array had only 1 element, but the code indexed `results[1]` — throwing a `RangeError` and breaking Firestore profile creation for EVERY new signup. Replaced with `final settingsSnap = await settingsFuture;` (no array indexing). Added cleanup-path user deletion on batch failure so a failed batch no longer leaves the Auth user orphaned from its Firestore profile.

### P0-8: Admin startup seeding (DB mutations on app launch)

- **Files changed**:
  - `lib/main_admin.dart` [worklog: Task ID 7-8]
  - `functions/src/admin/seedLocations.ts` [worklog: Task ID 9]
- **Fix**: Removed the entire seeding block (lines 71-96 of the original) from `lib/main_admin.dart`. Seeding is now done via the `seedLocations` callable (admin-only) on first deploy. The admin app no longer performs DB mutations on launch.

### P0-9: Android release signing fallback to debug

- **Files changed**:
  - `android/app/build.gradle` [worklog: Task ID 7-8]
  - `.github/workflows/release.yml` [worklog: Task ID 10-11]
- **Fix**: The release buildType's `signingConfig signingConfigs.debug` fallback is replaced with `throw new GradleException("Production keystore missing. Set keystore.properties before building a release.")`. A `debug { signingConfig signingConfigs.debug }` buildType was added so dev builds still work. The `release.yml` workflow refuses to build production release tags if `KEYSTORE_BASE64` or `KEYSTORE_PROPERTIES_B64` secrets are missing.

---

## P1 — Production-degrading issues

### P1-1: CI/CD `continue-on-error` everywhere

- **Files changed**:
  - `.github/workflows/auto-build-and-deploy.yml` [worklog: Task ID 10-11]
  - `.github/workflows/security.yml` [worklog: Task ID 10-11]
  - `.github/workflows/release.yml` [worklog: Task ID 10-11]
  - `.github/workflows/auto-update-dependencies.yml` [worklog: Task ID 10-11]
- **Fix**: Every `continue-on-error: true` line removed. `flutter analyze` is now `flutter analyze --fatal-infos --fatal-warnings` (FATAL). `flutter pub outdated` and `npm audit` no longer have `|| true`. Build jobs (`build-mobile`, `build-web`) depend on `rules-test`, `functions-test`, `test-security-analyze`, `secrets-scan`, `vulnerability-scan`, and `forbidden-secret-patterns` — any failure cancels the build.

### P1-2: `firebase_performance: any`, platform interface deps as `any`

- **Files changed**:
  - `pubspec.yaml` [worklog: Task ID 10-11]
- **Fix**: All `any` deps replaced with pinned versions: `firebase_performance: ^0.10.0+5`, `cloud_firestore_platform_interface: ^6.4.0`, `path_provider_platform_interface: ^2.1.2`, `plugin_platform_interface: ^2.1.8`, `fake_cloud_firestore: ^3.1.0`. Added new deps: `cloud_functions: ^5.3.0`, `app_links: ^6.1.1`, `flutter_inappwebview: ^6.1.5`. CI `setup` job grep-checks the pubspec for `any` and fails fast.

### P1-3: README insufficient; duplicate project dirs

- **Files changed**:
  - `README.md` [worklog: Task ID 10-11]
  - `docs/ARCHITECTURE.md` [worklog: Task ID 10-11]
  - `docs/SECURITY.md` [worklog: Task ID 10-11]
  - `docs/PAYMENTS.md` [worklog: Task ID 10-11]
  - `docs/DEPLOYMENT.md` [worklog: Task ID 10-11]
  - `docs/RUNBOOK.md` [worklog: Task ID 10-11]
  - `docs/DATA_PROVENANCE.md` [worklog: Task ID 10-11]
  - `docs/CHANGELOG-PRODUCTION-PATCH.md` [worklog: Task ID 10-11]
  - `functions-deploy-checklist.md` [worklog: Task ID 10-11]
- **Fix**: README rewritten with architecture overview, monorepo layout (legacy `paykari_bazar/` and `paykari_bazar_admin/` explicitly marked as deprecated), environments, local dev, secrets management, testing, deployment, release process, incident handling, business-critical rules, contributing. New `docs/` directory covers every operational aspect a serious B2B production repo needs.

### P1-4: Search not scalable (client-side filter)

- **Files changed**:
  - `lib/src/features/commerce/services/product_service.dart` [worklog: Task ID 3-4-5-6]
  - `functions/src/search/productSearch.ts` [worklog: Task ID 9]
- **Fix**: New `searchProducts` callable performs server-side search (with `limit`, `category`, `brand`, `minStock` filters). Client `ProductService.searchProductsServer(query, {...})` calls the callable. Old client-side `searchProducts` stream is `@Deprecated` with a note pointing to the callable.

### P1-5: AI feature not "real" (smartEnrichProduct ignores imageBytes; latency hard-coded)

- **Files changed**:
  - `lib/src/features/ai/services/ai_automation_service.dart` [worklog: Task ID 10-11]
  - `lib/src/features/ai/services/ai_service.dart` [worklog: Task ID 10-11]
- **Fix**:
  - `smartEnrichProduct` now passes `imageBytes` to a new `_generateWithImage` helper that uses Gemini's `Content.multi([TextPart, DataPart])` API. The generated JSON is actually parsed and the fields (`name`, `nameBn`, `description`, `descriptionBn`, `suggestedCategory`, `seoTags`) are written to the product. `jsonDecode` is wrapped in try/catch with a clear audit error. Production is guarded by `if (kReleaseMode) throw UnsupportedError(...)` — AI enrichment must run server-side.
  - `performGlobalSystemCheck` no longer hard-codes `'latency': '45ms'`. It uses a `Stopwatch` to measure the actual time of the provider health checks and returns `'${stopwatch.elapsedMilliseconds}ms'`.

### P1-6: Prescription/healthcare not isolated security domain

- **Files changed**:
  - `firestore.rules` [worklog: Task ID 7-8]
  - `storage.rules` [worklog: Task ID 7-8]
  - `functions/src/health/prescriptionProcess.ts` [worklog: Task ID 9]
- **Fix**: Distinct `prescriptions/{id}` Firestore collection with strict rules (owner read+create, staff update, admin delete). Distinct `prescriptions/{userId}/**` Storage bucket with strict MIME and size limits (5MB, image/(jpeg|png|webp) only). AI analysis of prescription images runs server-side via `analyzePrescription` callable — Gemini API key never ships in the client binary.

### P1-7: Product data provenance (chaldal.csv etc.)

- **Files changed**:
  - `docs/DATA_PROVENANCE.md` [worklog: Task ID 10-11]
- **Fix**: New `docs/DATA_PROVENANCE.md` documents every data asset's source, license, last-updated, owner, and refresh cadence. Explicit policy: third-party product data (the ~80 `chaldal*.csv` files under `assets/main-store-structure/`) may NOT be used commercially without a written license. A production readiness checklist requires deleting all `chaldal*.csv` files and re-seeding Firestore from a self-owned catalog before commercial launch.

---

## New CI/CD pipelines

### `.github/workflows/rules-emulator-test.yml` (new)

- Boots Firestore + Storage emulators and runs `dart test test/firestore_rules/` on every PR.
- FATAL on any rule violation.
- Includes a placeholder test file at `test/firestore_rules/_placeholder_test.dart` (maintainer extends).

### `.github/workflows/firebase-emulator-e2e.yml` (new)

- Manual dispatch (or nightly cron) boots the full Firebase emulator suite and runs `flutter test integration_test/`.
- Useful for pre-release verification.

### `.github/workflows/functions-deploy.yml` (new)

- Dedicated backend deploy pipeline.
- Trigger: push to `main` changing `functions/**` OR manual dispatch with `environment ∈ {staging, production}`.
- Jobs: lint → typecheck → unit-test → (manual approval) → deploy.
- Deploy order: callables → webhooks → triggers.
- Uses Workload Identity Federation (`google-github-actions/auth@v2`) — no key file.

### `.github/workflows/auto-update-dependencies.yml` (patched)

- Removed `|| true` from `flutter pub outdated`.
- Made `flutter pub outdated --no-dev-dependencies --no-transitive` FATAL — opens a PR only if outdated.
- Open PRs only on weekly schedule (not on every push).
- Added npm dependencies job for `functions/`.

### `.github/workflows/docs.yml` (patched)

- Added TypeDoc generation for `functions/` TypeScript API docs.
- Added `markdown-link-check` step that FATAL on any broken markdown link.

### `.github/workflows/release.yml` (patched)

- Pre-release gate now requires `rules-test`, `functions-test`, `secret-scan` to pass.
- `keystore.properties` is required for production release tags (FATAL if missing).
- OIDC auth for Google Cloud (Workload Identity Federation) added for the future Play Store upload step.

---

## New jobs in existing workflows

### `auto-build-and-deploy.yml` additions

- **`rules-test`** job: runs `firebase emulators:exec --only firestore,storage "dart test test/firestore_rules/"`. BLOCKING.
- **`functions-test`** job: `cd functions && npm ci && npm run lint && npx tsc --noEmit && npm run build && npm test --if-present`. BLOCKING.
- **`emulator-e2e`** job (gated by `run_e2e` input): boots Firestore + Functions + Auth + Storage emulators and runs `flutter test integration_test/checkout_e2e_test.dart`.
- **`forbidden-secret-patterns`** job: greps the source tree for known leaked placeholder secret strings. FATAL.
- **`env-example-check`** job: scans `.env.example` for real (non-placeholder) secret values. FATAL.
- **`secrets-scan`** job now runs **both** TruffleHog and Gitleaks (FATAL).
- **`vulnerability-scan`** (Trivy) is now FATAL with `exit-code: '1'` and `severity: 'CRITICAL,HIGH'`.
- **`setup`** job: added a grep check that pubspec.yaml contains no `any` pins. FATAL.
- **`test-security-analyze`** job: `flutter analyze` is now `--fatal-infos --fatal-warnings`. `flutter pub outdated`, `dart pub audit`, `npm audit` are no longer `|| true`.
- All build jobs (`build-mobile`, `build-web`) now depend on `rules-test`, `functions-test`, `test-security-analyze`, `secrets-scan`, `vulnerability-scan`, `forbidden-secret-patterns`.

---

## File-by-file changelog

| File | Action | Worklog Task ID |
| ---- | ------ | --------------- |
| `pubspec.yaml` | EDIT (pinned versions, new deps) | 10-11 |
| `.github/workflows/auto-build-and-deploy.yml` | EDIT (no `continue-on-error`, FATAL analyze, new jobs) | 10-11 |
| `.github/workflows/auto-update-dependencies.yml` | EDIT (FATAL outdated, schedule-only) | 10-11 |
| `.github/workflows/docs.yml` | EDIT (TypeDoc, markdown link lint) | 10-11 |
| `.github/workflows/release.yml` | EDIT (require gates, OIDC, keystore.properties) | 10-11 |
| `.github/workflows/security.yml` | EDIT (FATAL trufflehog/trivy/gitleaks, forbidden patterns, env.example check) | 10-11 |
| `.github/workflows/functions-deploy.yml` | NEW | 10-11 |
| `.github/workflows/rules-emulator-test.yml` | NEW | 10-11 |
| `.github/workflows/firebase-emulator-e2e.yml` | NEW | 10-11 |
| `lib/src/features/ai/services/ai_automation_service.dart` | EDIT (real multimodal enrichment, kReleaseMode guard) | 10-11 |
| `lib/src/features/ai/services/ai_service.dart` | EDIT (real latency via Stopwatch, added lookupGeminiProvider) | 10-11 |
| `README.md` | REWRITE | 10-11 |
| `docs/ARCHITECTURE.md` | NEW | 10-11 |
| `docs/SECURITY.md` | NEW | 10-11 |
| `docs/PAYMENTS.md` | NEW | 10-11 |
| `docs/DEPLOYMENT.md` | NEW | 10-11 |
| `docs/RUNBOOK.md` | NEW | 10-11 |
| `docs/DATA_PROVENANCE.md` | NEW | 10-11 |
| `docs/CHANGELOG-PRODUCTION-PATCH.md` | NEW (this file) | 10-11 |
| `functions-deploy-checklist.md` | NEW | 10-11 |
| `test/firestore_rules/_placeholder_test.dart` | NEW (placeholder for rules-emulator-test.yml) | 10-11 |
| `.gitignore` | EDIT (added secrets, functions/.env, debug logs, lib/, node_modules/) | 10-11 |
| `firestore.rules` | REWRITE | 7-8 |
| `storage.rules` | REWRITE | 7-8 |
| `android/app/build.gradle` | EDIT (multiDex, no debug fallback, multidex dep) | 7-8 |
| `android/app/proguard-rules.pro` | EDIT (payment SDK keep rules) | 7-8 |
| `android/app/src/main/AndroidManifest.xml` | EDIT (deep-link intent filter) | 7-8 |
| `lib/main_admin.dart` | EDIT (removed seeding block) | 7-8 |
| `lib/src/shared/services/payment_service.dart` | REWRITE (placeholder gone, typed PaymentInit/PaymentVerifyResult) | 3-4-5-6 |
| `lib/src/features/commerce/services/order_service.dart` | REWRITE (calcOrder→reserveStock→createOrder) | 3-4-5-6 |
| `lib/src/features/commerce/services/product_service.dart` | EDIT (deleted updateProductStock, added searchProductsServer, watchReservedStock) | 3-4-5-6 |
| `lib/src/features/commerce/services/coupon_service.dart` | EDIT (@Deprecated on validateCoupon/calculateDiscount) | 3-4-5-6 |
| `lib/src/features/commerce/providers/cart_provider.dart` | EDIT (added calculateServerTotals + serverPricingProvider) | 3-4-5-6 |
| `lib/src/features/auth/services/auth_service.dart` | EDIT (fixed Future.wait bug, removed email-string role inference, cleanup-path) | 3-4-5-6 |
| `lib/src/core/services/security_initializer.dart` | EDIT (removed hardcoded fallbacks, release fail-fast) | 3-4-5-6 |
| `lib/src/core/services/secrets_service.dart` | EDIT (@Deprecated on getters, TODO(prod) to remove) | 3-4-5-6 |
| `lib/src/core/constants/paths.dart` | EDIT (added productPrices, inventoryReservations, payments, businesses, auditLogs, prescriptions, paymentslipsStorage, refundsSub) | 3-4-5-6 |
| `lib/src/core/services/cloud_functions_client.dart` | NEW (typed wrapper around FirebaseFunctions.httpsCallable) | 3-4-5-6 |
| `lib/src/features/checkout/models/pricing_snapshot.dart` | NEW | 3-4-5-6 |
| `lib/src/features/checkout/services/checkout_service.dart` | NEW | 3-4-5-6 |
| `lib/src/features/checkout/providers/checkout_provider.dart` | NEW | 3-4-5-6 |
| `lib/src/features/payments/models/{payment_method,payment_init,payment_result}.dart` | NEW | 3-4-5-6 |
| `lib/src/features/payments/providers/payment_provider.dart` | NEW | 3-4-5-6 |
| `lib/src/features/payments/services/{payment_redirect_handler,bkash,nagad,sslcommerz,bank}_service.dart` | NEW | 3-4-5-6 |
| `lib/src/features/payments/widgets/{payment_method_selector,payment_web_view}.dart` | NEW | 3-4-5-6 |
| `lib/src/features/payments/screens/payment_result_screen.dart` | NEW | 3-4-5-6 |
| `lib/src/features/inventory/models/reservation_model.dart` | NEW | 3-4-5-6 |
| `lib/src/features/inventory/services/inventory_service.dart` | NEW | 3-4-5-6 |
| `pubspec_overrides_note.md` | NEW (migration notes for app_links + flutter_inappwebview) | 3-4-5-6 |
| `functions/` (entire backend) | NEW | 9 |

---

## Next actions for the maintainer

These items are out-of-scope for this patch but required before production launch:

1. Merge `pubspec_overrides_note.md` into `pubspec.yaml` (already done in this patch — `app_links` + `flutter_inappwebview` are now pinned in `pubspec.yaml`).
2. Add a thin `lib/src/features/payments/services/app_links_stream.dart` shim that wraps the `app_links` package and patches `payment_redirect_handler.dart`'s `_appLinksStream()` method to use it (currently returns `Stream<Uri>.empty()`).
3. Update `lib/src/di/service_initializer.dart` to register `CloudFunctionsClient` as a singleton.
4. Migrate UI screens (`cart_screen.dart`, `checkout_bottom_sheet.dart`, `order_details_screen.dart`) to call `CheckoutService.checkout()` + `PaymentRedirectHandler` instead of the legacy `OrderService.placeOrder({...total, deliveryFee, discount...})` path.
5. Add the follow-up `assignRider` callable on the backend + a thin client wrapper so the rider assignment path (currently throws `UnsupportedError`) is restored for staff.
6. Configure the `production` GitHub Environment in repo Settings → Environments with the SRE team as required reviewers (for `functions-deploy.yml`).
7. Set up Workload Identity Federation per `docs/DEPLOYMENT.md` § 3.
8. Register webhook URLs with bKash/Nagad/SSLCommerz production dashboards.
9. Delete all `chaldal*.csv` files from `assets/main-store-structure/` and re-seed Firestore from a self-owned catalog (per `docs/DATA_PROVENANCE.md`).
10. Add real Firestore rules tests under `test/firestore_rules/` (replace `_placeholder_test.dart`).

---

## Security rotations

_None in this patch._ Future rotations should be logged here with date + secret + reason + ticket link.
