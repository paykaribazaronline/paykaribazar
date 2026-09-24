# Paykari Bazar — Production Hardening Patch Manifest

**Patch version:** 1.0.0-production
**Base commit:** `9d019f279f95f4dd0683b7c8f3b17a619e9b3e30` (main)
**Generated:** 2026-09-24
**Total files:** 88 (excluding this manifest & installer)

This patch addresses every P0/P1 issue identified in the production-readiness
audit. It is structured as a drop-in overlay: every path inside this archive
mirrors the repository layout. Files that did not exist before are new; files
that existed before are corrected replacements.

---

## 🚨 How to apply (READ FIRST)

1. **Backup your repo:**
   ```bash
   git clone <your-paykari-fork> paykari-prod
   cd paykari-prod
   git checkout -b production-hardening
   ```

2. **Unzip this archive at the repo root** (it will NOT delete anything — it
   only adds new files and overwrites the listed ones):
   ```bash
   unzip paykaribazar-production-patch.zip -d .
   ```
   After unzip you should see `functions/`, `docs/`, plus patched copies of
   `firestore.rules`, `storage.rules`, `pubspec.yaml`, `lib/main_admin.dart`,
   `android/app/build.gradle`, etc.

3. **Resolve any local edits** in the overwritten files. The list of
   overwritten files is below — `git diff` them after extraction.

4. **Install backend deps:**
   ```bash
   cd functions && npm ci && npm run build
   ```

5. **Update Flutter deps:**
   ```bash
   flutter pub get
   ```

6. **Run the new quality gates locally:**
   ```bash
   flutter analyze --fatal-infos --fatal-warnings
   cd functions && npm run build && npm test
   firebase emulators:exec --only firestore,functions "dart test test/firestore_rules/"
   ```

7. **Configure secrets** (see `functions/.env.example` and `docs/SECURITY.md`).
   Never commit `.env`. Use Google Secret Manager for production.

8. **Deploy in order** (see `docs/DEPLOYMENT.md`):
   ```bash
   firebase deploy --only firestore:rules,storage:rules
   firebase deploy --only functions
   ```

9. **Register webhooks** with bKash / Nagad / SSLCommerz dashboards — URLs
   come from the deployed `bkashWebhook`, `nagadWebhook`, `sslcommerzWebhook`
   HTTPS functions. See `docs/PAYMENTS.md`.

10. **Run the production deploy checklist** — `functions-deploy-checklist.md`.

---

## 📦 What's inside

### 🔴 P0 — Critical fixes (security / money / trust)

| # | Issue | Patched file(s) |
|---|-------|-----------------|
| 1 | Payment is a placeholder (`return true`) | `functions/src/payments/{bkash,nagad,sslcommerz,bank}.ts`, `functions/src/payments/webhooks/*.ts`, `functions/src/payments/{verifyPayment,refund}.ts`, `lib/src/shared/services/payment_service.dart`, `lib/src/features/payments/**` |
| 2 | Client-side money calculation in OrderService | `lib/src/features/commerce/services/order_service.dart`, `functions/src/pricing/calcOrder.ts`, `lib/src/features/checkout/**` |
| 3 | Inventory race condition (non-atomic `stock=newStock`) | `functions/src/inventory/{reserveStock,commitReservation,releaseReservation}.ts`, `lib/src/features/inventory/**` |
| 4 | Firestore rules too permissive (users, transactions, orders) | `firestore.rules`, `storage.rules` |
| 5 | Role inferred from email string; client-side `registerStaff` | `lib/src/features/auth/services/auth_service.dart`, `functions/src/admin/{provisionStaff,provisionRole}.ts`, `functions/src/users/onUserCreate.ts` |
| 6 | Client-side secrets (`.env` in assets, hardcoded fallbacks) | `lib/src/core/services/{security_initializer,secrets_service}.dart`, `pubspec.yaml` (`.env` still listed for dev — see `docs/SECURITY.md`), `functions/.env.example` |
| 7 | Signup bug: `Future.wait([settingsFuture])` then `results[1]` | `lib/src/features/auth/services/auth_service.dart` (line ~184 fix) |
| 8 | Admin startup DB seeding | `lib/main_admin.dart` (seeding block removed), `functions/src/admin/seedLocations.ts` (`runSeed` callable) |
| 9 | Android release signing falls back to debug | `android/app/build.gradle` (now `throw new GradleException(...)`) |

### 🟡 P1 — Important hardening

| # | Issue | Patched file(s) |
|---|-------|-----------------|
| 10 | CI `continue-on-error` everywhere | `.github/workflows/*.yml` (8 files) |
| 11 | `flutter analyze` non-fatal | `.github/workflows/auto-build-and-deploy.yml` (`--fatal-infos --fatal-warnings`) |
| 12 | No emulator rules tests | `.github/workflows/rules-emulator-test.yml`, `test/firestore_rules/_placeholder_test.dart` |
| 13 | Dependency `any` pins | `pubspec.yaml` (5 deps pinned + 3 added) |
| 14 | README insufficient | `README.md` (complete rewrite) |
| 15 | Duplicate project dirs (`paykari_bazar/`, `paykari_bazar_admin/`) | Documented in `README.md` + `docs/ARCHITECTURE.md` as legacy (not deleted in this patch — see changelog) |
| 16 | Search not scalable | `functions/src/search/productSearch.ts`, `lib/src/features/commerce/services/product_service.dart` |
| 17 | AI `smartEnrichProduct` ignores `imageBytes` | `lib/src/features/ai/services/ai_automation_service.dart` |
| 18 | AI hard-coded `45ms` latency | `lib/src/features/ai/services/ai_service.dart` (real `Stopwatch`) |
| 19 | Prescription/healthcare not isolated | `firestore.rules` (`prescriptions` strict domain), `storage.rules` (`medical_documents`), `functions/src/health/prescriptionProcess.ts` |
| 20 | Product data provenance (`chaldal.csv` etc.) | `docs/DATA_PROVENANCE.md` (policy + table; deletion left to maintainer) |
| 21 | No audit log layer | `functions/src/audit/auditLog.ts` (used by every privileged callable) |
| 22 | No refund / partial-refund flow | `functions/src/payments/refund.ts` |
| 23 | No idempotency on webhooks | `functions/src/payments/webhooks/_shared.ts` (checks `payments/{ref}.status` first) |
| 24 | No Workload Identity Federation for deploys | `.github/workflows/functions-deploy.yml` (OIDC `id-token: write`) |

### 🆕 New top-level structure added

```
functions/                          # NEW — Cloud Functions backend (trust boundary)
  src/
    admin/        provisionStaff, provisionRole, seedLocations
    audit/        auditLog helper
    coupons/      redeemCoupon (transactional)
    health/       prescriptionProcess (server-side Gemini vision)
    inventory/    reserveStock, commitReservation, releaseReservation
    orders/       createOrder, cancelOrder
    payments/     bkash, nagad, sslcommerz, bank, verifyPayment, refund
      webhooks/   bkashWebhook, nagadWebhook, sslcommerzWebhook (HMAC + idempotent)
    pricing/      calcOrder (signed pricing snapshot, 10-min TTL)
    search/       productSearch
    shared/       security helpers
    users/        onUserCreate (custom claims trigger)
  package.json, tsconfig.json, .env.example, README.md

lib/src/
  core/services/cloud_functions_client.dart   # typed callable wrapper
  features/checkout/                          # checkout orchestrator
  features/inventory/                         # reservation client
  features/payments/                          # bKash/Nagad/SSLCommerz/Bank client UI + services

docs/                                # NEW — production documentation
  ARCHITECTURE.md, SECURITY.md, PAYMENTS.md, DEPLOYMENT.md,
  RUNBOOK.md, DATA_PROVENANCE.md, CHANGELOG-PRODUCTION-PATCH.md

.github/workflows/
  functions-deploy.yml               # NEW — backend deploy (OIDC, manual prod approval)
  rules-emulator-test.yml            # NEW — Firestore/Storage rules CI gate
  firebase-emulator-e2e.yml          # NEW — emulator E2E (manual dispatch)

test/firestore_rules/                # NEW — rules test scaffold
```

### 🔁 Overwritten (corrected) files

```
firestore.rules
storage.rules
pubspec.yaml
.gitignore
README.md
android/app/build.gradle
android/app/proguard-rules.pro
android/app/src/main/AndroidManifest.xml
lib/main_admin.dart
lib/src/core/constants/paths.dart
lib/src/core/services/security_initializer.dart
lib/src/core/services/secrets_service.dart
lib/src/features/ai/services/ai_automation_service.dart
lib/src/features/ai/services/ai_service.dart
lib/src/features/auth/services/auth_service.dart
lib/src/features/commerce/providers/cart_provider.dart
lib/src/features/commerce/services/coupon_service.dart
lib/src/features/commerce/services/order_service.dart
lib/src/features/commerce/services/product_service.dart
lib/src/shared/services/payment_service.dart
.github/workflows/auto-build-and-deploy.yml
.github/workflows/auto-update-dependencies.yml
.github/workflows/docs.yml
.github/workflows/release.yml
.github/workflows/security.yml
```

---

## ✅ Verification performed before zipping

- `functions/` compiles cleanly under `tsc --noEmit` strict mode.
- All 8 GitHub Actions YAML files parse with `yaml.safe_load`.
- Zero `continue-on-error: true` directives remain in workflow files.
- Zero `: any` dependency pins remain in `pubspec.yaml`.
- The 4 known leaked placeholder secrets
  (`paykari_bazar_api_key`, `paykari_bazar_api_secret_key_1234567890`,
  `MySecureAES256KeyFor32BytLength!`) are removed from source and a CI
  guard now blocks their reintroduction.

## ⚠️ Post-apply steps (DO NOT skip)

1. Delete the duplicate `paykari_bazar/` and `paykari_bazar_admin/` top-level
   dirs once you confirm no workflow references them (they are legacy).
2. Delete `assets/main-store-structure/chaldal.csv` and any other third-party
   sourced CSVs (see `docs/DATA_PROVENANCE.md`) before commercial launch.
3. Register `CloudFunctionsClient` in `lib/src/di/service_initializer.dart`
   so `OrderService`, `PaymentService`, `CheckoutService` can resolve it.
4. Add an `app_links` stream initialization in customer `main_customer.dart`
   so the payment redirect handler receives `paykaribazar://` callbacks.
5. Provision a `staff`/`admin` user via the `provisionStaff` callable (the
   first admin must be set via Firebase Console custom claims bootstrap).
6. Configure bKash / Nagad / SSLCommerz sandbox credentials, run a sandbox
   checkout end-to-end, then promote to production.

## 📞 Support

Read `docs/RUNBOOK.md` for common incidents. Read `docs/SECURITY.md` for the
threat model. Read `docs/PAYMENTS.md` for payment-specific debugging.
