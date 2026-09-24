# Paykari Bazar

[![CI](https://github.com/paykaribazaronline/paykaribazar/actions/workflows/auto-build-and-deploy.yml/badge.svg)](https://github.com/paykaribazaronline/paykaribazar/actions/workflows/auto-build-and-deploy.yml)
[![Security](https://github.com/paykaribazaronline/paykaribazar/actions/workflows/security.yml/badge.svg)](https://github.com/paykaribazaronline/paykaribazar/actions/workflows/security.yml)
[![License: Proprietary](https://img.shields.io/badge/license-proprietary-red.svg)](#license)

**Paykari Bazar** is a Bangladesh-focused wholesale **B2B commerce platform** that lets retailers, resellers, and the Paykari operations team discover products, place orders, reserve inventory transactionally, pay via bKash / Nagad / SSLCommerz / Bank transfer, and dispatch — with every money / inventory / payment decision enforced **server-side** by Cloud Functions.

- Version: see `pubspec.yaml`
- Last Updated: see commit history

---

## What is Paykari Bazar?

Paykari Bazar is a B2B commerce platform targeted at the Bangladesh wholesale market. Customers are small-business resellers (retailers, pharmacies, grocery shops, restaurants). The platform offers:

- Wholesale catalog with tiered pricing per business segment
- Real-time inventory reservation with HMAC-signed pricing snapshots (no client-side math)
- Payments via bKash, Nagad, SSLCommerz (cards + mobile banking), Bank transfer (slip upload), and COD
- Cash-on-delivery, loyalty, coupons, prescriptions (healthcare sub-domain)
- Admin console for catalog, orders, logistics, audit, finance
- Two Flutter apps from one codebase: a **customer** app (`lib/main_customer.dart`) and an **admin** app (`lib/main_admin.dart`)
- Backend: Firebase Auth + App Check + Cloud Functions (2nd gen, `asia-southeast1`) + Firestore + Cloud Storage

---

## Architecture overview

```
                         ┌────────────────────────────────────────────┐
                         │              Flutter (Dart)                 │
                         │                                            │
                         │  lib/main_customer.dart (customer app)     │
                         │  lib/main_admin.dart    (admin app)        │
                         │                                            │
                         │  Riverpod state, go_router, Firebase SDK  │
                         └───────────────┬────────────────────────────┘
                                         │  (callable, region: asia-southeast1)
              ┌──────────────────────────┴───────────────────────────┐
              │                TRUST BOUNDARY                         │
              │   (no client ever mutates money / stock / payments)  │
              └──────────────────────────┬───────────────────────────┘
                                         │
        ┌────────────────────────────────┴─────────────────────────────┐
        │              Firebase Auth + App Check                        │
        │  Custom claims: { role, admin, staff, reseller, rider }       │
        └────────────────────────────────┬─────────────────────────────┘
                                         │
        ┌────────────────────────────────┴─────────────────────────────┐
        │  Cloud Functions (TypeScript, 2nd gen, asia-southeast1)      │
        │  functions/src/                                                │
        │                                                                │
        │   payments/   bkash.ts, nagad.ts, sslcommerz.ts, bank.ts      │
        │               verifyPayment.ts, refund.ts                    │
        │               webhooks/{bkash,nagad,sslcommerz}Webhook.ts    │
        │   pricing/    calcOrder.ts        (HMAC-signed snapshot)      │
        │   inventory/  reserveStock.ts, releaseReservation.ts,        │
        │               commitReservation.ts                           │
        │   orders/     createOrder.ts, cancelOrder.ts                  │
        │   coupons/    redeem.ts                                       │
        │   search/     productSearch.ts                               │
        │   admin/      provisionStaff.ts, provisionRole.ts,            │
        │               seedLocations.ts                               │
        │   users/      onUserCreate.ts (Firestore trigger)            │
        │   audit/      auditLog.ts                                    │
        │   health/     prescriptionProcess.ts (Gemini AI)             │
        └────────────────────────────────┬─────────────────────────────┘
                                         │  Admin SDK (bypasses rules)
        ┌────────────────────────────────┴─────────────────────────────┐
        │                  Firestore + Cloud Storage                     │
        │                                                                │
        │  Collections:                                                  │
        │    users, businesses, hub/data/products, hub/data/productPrices│
        │    inventoryReservations, orders, payments, auditLogs,         │
        │    settings/coupons, prescriptions, private_chats              │
        │                                                                │
        │  Storage:                                                      │
        │    profile_photos, products, paymentslips, prescriptions,      │
        │    chat_attachments, medical_documents                        │
        │                                                                │
        │  Security rules: locked-down; client writes denied for        │
        │  money / stock / role / payment / ledger                      │
        └────────────────────────────────────────────────────────────────┘
```

The trust boundary is the Cloud Functions layer. **The client never computes money, never assigns role, never mutates stock.** All money/inventory/payment decisions route through signed callables that re-verify on the server.

---

## Monorepo layout

```
.
├── lib/                              # Canonical Flutter codebase
│   ├── main_customer.dart            # Customer app entry point
│   ├── main_admin.dart               # Admin app entry point
│   └── src/
│       ├── core/                     # DI, constants, base classes, security
│       ├── di/                       # service_locator, service_initializer
│       ├── features/
│       │   ├── admin/                # Admin console widgets
│       │   ├── ai/                   # AI services (dev-only client enrichment)
│       │   ├── auth/                 # login, signup, providers
│       │   ├── cart/                 # cart UI
│       │   ├── checkout/             # checkout service + provider
│       │   ├── commerce/             # order, product, coupon services
│       │   ├── inventory/            # reservation model + service
│       │   ├── payments/             # bKash/Nagad/SSL/Bank services + UI
│       │   └── ...
│       └── models/                   # domain models
├── functions/                        # TypeScript Cloud Functions (the backend)
│   ├── src/
│   │   ├── payments/                 # bKash, Nagad, SSLCommerz, Bank
│   │   ├── pricing/                  # calcOrder (HMAC-signed snapshot)
│   │   ├── inventory/                # reserveStock, releaseReservation, commitReservation
│   │   ├── orders/                   # createOrder, cancelOrder
│   │   ├── coupons/                  # redeemCoupon
│   │   ├── search/                   # productSearch (Algolia-style server-side)
│   │   ├── admin/                    # provisionStaff, provisionRole, seedLocations
│   │   ├── users/                    # onUserCreate trigger
│   │   ├── audit/                    # auditLog helper
│   │   ├── health/                   # prescriptionProcess (Gemini AI)
│   │   └── index.ts                  # entry — exports all callables
│   ├── package.json
│   └── tsconfig.json
├── firestore.rules                   # locked-down rules (rules-emulator-tested)
├── storage.rules                     # locked-down rules
├── firebase.json                     # Firestore indexes + emulator config
├── android/                          # Android shell (customer + admin flavors)
├── ios/                              # iOS shell (future)
├── integration_test/                 # Flutter integration tests
├── test/                             # Dart unit tests
│   └── firestore_rules/              # Firestore / Storage rules tests
├── docs/                             # Production documentation (see below)
└── .github/workflows/                # CI/CD pipelines
    ├── auto-build-and-deploy.yml     # master pipeline (rules+functions+e2e)
    ├── auto-update-dependencies.yml  # weekly dependency PRs
    ├── docs.yml                      # docs build + markdown link lint
    ├── release.yml                   # tagged release pipeline
    ├── security.yml                  # trufflehog+gitleaks+trivy+patterns
    ├── functions-deploy.yml          # backend deploy (WIF, manual approval)
    ├── rules-emulator-test.yml       # Firestore/Storage rules test
    └── firebase-emulator-e2e.yml     # full emulator E2E (manual dispatch)

# Documentation
docs/ARCHITECTURE.md                  # collection-by-collection schema, state machines
docs/SECURITY.md                      # threat model, trust boundary, secret mgmt
docs/PAYMENTS.md                      # bKash/Nagad/SSLCommerz/Bank deep dive
docs/DEPLOYMENT.md                    # dev → staging → production step-by-step
docs/RUNBOOK.md                       # incident handling playbook
docs/DATA_PROVENANCE.md               # data asset licenses & ownership
docs/CHANGELOG-PRODUCTION-PATCH.md    # this patch's changelog
functions-deploy-checklist.md         # pre-flight checklist for backend deploy
```

### ⚠️ Legacy duplicate directories

`paykari_bazar/` and `paykari_bazar_admin/` at the repo root are **legacy duplicates** from an earlier multi-app scaffold. They are NOT built, NOT tested, and NOT deployed by the CI pipeline. **Do not edit them.** They will be removed in a follow-up cleanup PR. The canonical codebase is `lib/` + `functions/`.

---

## Environments

Three Firebase projects are used:

| Environment   | Purpose                                         | `.firebaserc` alias |
| ------------- | ----------------------------------------------- | ------------------- |
| `paykari-dev` | Local + CI development                          | `default`           |
| `paykari-staging` | Pre-release verification                     | `staging`           |
| `paykari-prod` | Production — Bangladesh wholesale traffic       | `production`        |

Switch projects with the Firebase CLI:

```bash
firebase use default           # dev
firebase use staging           # staging
firebase use production        # production
firebase use --add             # add a new alias interactively
```

The CI pipelines (`.github/workflows/functions-deploy.yml`) select the project via `${{ secrets.FIREBASE_PROJECT_ID }}` and the `environment:` block (staging auto-deploys on push to main; production requires manual dispatch + reviewer approval).

---

## Local development

### Prerequisites

- **Flutter 3.27+** (`flutter --version` should report Dart ≥ 3.5)
- **Node.js 20 LTS** for Cloud Functions (`node --version`)
- **Java 17** for the Firebase emulator
- **Firebase CLI**: `npm install -g firebase-tools`
- **Java 17** (Android Gradle plugin requirement)
- An Android emulator or physical device for the Flutter apps

### Bootstrap

```bash
# Clone
git clone <repo-url> paykari-bazar
cd paykari-bazar

# Flutter client
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # if you use Hive generators

# Cloud Functions
cd functions
npm ci
npm run build
cd ..

# Firebase emulator (boots Firestore, Functions, Auth, Storage)
firebase emulators:start --only firestore,functions,auth,storage
```

### Running the apps

```bash
# Customer app
flutter run -t lib/main_customer.dart --flavor customer

# Admin app
flutter run -t lib/main_admin.dart --flavor admin
```

### Running tests

```bash
# Unit tests
flutter test

# Backend tests
cd functions && npm test

# Firestore / Storage rules tests against the emulator
firebase emulators:exec --only firestore,storage "dart test test/firestore_rules/"

# Integration tests (E2E)
firebase emulators:exec --only firestore,functions,auth,storage \
  "flutter test integration_test/"
```

---

## Secrets management

**CRITICAL**: All production secrets live in **Google Secret Manager** and are referenced by Cloud Functions via the Firebase Functions runtime config (`functions.config()` or `process.env`). They are NEVER in `.env` files in the client binary, and NEVER in the GitHub Actions `secrets` directly used by client builds.

- `.env` (client) — **dev-only**, git-ignored. Used by `flutter_dotenv` to load development-only keys (e.g. a sandbox Gemini API key). In release builds this file is excluded.
- `.env.example` — checked in, contains only placeholders (e.g. `GEMINI_API_KEY=your_gemini_api_key_here`). CI verifies it has no real secrets (see `.github/workflows/security.yml`).
- `functions/.env` — backend secrets, git-ignored. The Functions runtime loads this when running under the emulator. In production these are mirrored to Google Secret Manager.
- `functions/.env.example` — checked in template listing every secret the backend needs.

### Backend secrets (see `functions/.env.example` for the canonical list)

- `BKASH_APP_KEY`, `BKASH_APP_SECRET`, `BKASH_USERNAME`, `BKASH_PASSWORD`
- `BKASH_CALLBACK_URL`, `BKASH_BASE_URL`
- `NAGAD_MERCHANT_ID`, `NAGAD_PUBLIC_KEY`, `NAGAD_PRIVATE_KEY`, `NAGAD_CALLBACK_URL`
- `SSLCOMMERZ_STORE_ID`, `SSLCOMMERZ_STORE_PASSWD`, `SSLCOMMERZ_BASE_URL`
- `BANK_ACCOUNTS_JSON` (JSON list of bank accounts for slip upload)
- `GEMINI_API_KEY` (server-side AI enrichment — never shipped to client)
- `PRICING_HMAC_SECRET` (signs pricing snapshots between `calcOrder` and `createOrder`)
- `SLACK_WEBHOOK_URL` (ops alerts)
- `SENTRY_DSN_FUNCTIONS`

### GitHub Actions secrets (workflows only)

- `FIREBASE_TOKEN`, `FIREBASE_PROJECT_ID` (per-environment)
- `GCP_FUNCTIONS_WIF_PROVIDER`, `GCP_FUNCTIONS_SERVICE_ACCOUNT` (Workload Identity Federation — no key file)
- `KEYSTORE_BASE64`, `KEYSTORE_PROPERTIES_B64` (Android release signing)
- `SHOREBIRD_AUTH_TOKEN`
- `SLACK_WEBHOOK`

See `docs/SECURITY.md` for the full secret-management policy and `docs/DEPLOYMENT.md` for the rotation procedure.

---

## Testing

| Layer            | Command                                                                                       | When                         |
| ---------------- | ---------------------------------------------------------------------------------------------- | ---------------------------- |
| Dart unit        | `flutter test`                                                                                | every PR                     |
| Backend unit     | `cd functions && npm test`                                                                    | every PR                     |
| Rules emulator   | `firebase emulators:exec --only firestore,storage "dart test test/firestore_rules/"`          | every PR                     |
| Integration E2E  | `firebase emulators:exec --only firestore,functions,auth,storage "flutter test integration_test/"` | nightly + manual dispatch    |
| Static analysis  | `flutter analyze --fatal-infos --fatal-warnings`                                              | every PR                     |
| Lint (functions) | `cd functions && npm run lint`                                                                 | every PR                     |

CI blocks merging on any failure. There is no `continue-on-error` anywhere in the pipeline.

---

## Deployment

### Backend (Cloud Functions + rules)

```bash
# Staging (auto on push to main)
firebase use staging
firebase deploy --only functions,firestore:rules,storage:rules

# Production (manual dispatch via workflow_dispatch)
#   see .github/workflows/functions-deploy.yml
firebase use production
firebase deploy --only functions:calcOrder,functions:reserveStock,...   # callables first
firebase deploy --only functions:bkashWebhook,functions:nagadWebhook,functions:sslcommerzWebhook   # webhooks
firebase deploy --only functions:onUserCreate                           # triggers last
```

Deploy order is enforced by the `functions-deploy.yml` workflow:
1. **Callable Cloud Functions** (calcOrder, reserveStock, createOrder, verifyPayment, ...)
2. **Webhook HTTP Functions** (bkash/nagad/sslcommerz webhook listeners)
3. **Firestore Trigger Functions** (onUserCreate)

See `docs/DEPLOYMENT.md` and `functions-deploy-checklist.md` for the full procedure.

### Flutter apps (Shorebird OTA + Play Store)

- **OTA patches**: Shorebird (`.github/workflows/auto-build-and-deploy.yml`)
- **Play Store**: fastlane (`.github/workflows/release.yml`) — currently gated behind `if: false` until the Play Console is provisioned
- **App Store**: not yet implemented (iOS shell exists in `ios/`)

### Android release signing

Production release builds require `keystore.properties` (the `release.yml` workflow refuses to build without it). The build.gradle fail-fasts on missing keystore — it will NOT silently fall back to debug signing.

---

## Release process

1. **PR** opened against `main`.
2. CI runs: rules-emulator-test, functions-test, dart unit test, analyze (fatal), trufflehog, gitleaks, trivy, forbidden-pattern check.
3. PR reviewer approves.
4. PR merged to `main` → staging deploy auto-triggers (`functions-deploy.yml`).
5. Smoke test on staging (manual — see `docs/RUNBOOK.md`).
6. Manual dispatch `functions-deploy.yml` with `environment=production` → reviewer approval gate.
7. Tag `vX.Y.Z` pushed → `release.yml` runs → APKs built → GitHub Release created → Shorebird patch.
8. Post-release: rollback runbook reviewed (`docs/RUNBOOK.md`).

---

## Incident handling

See [`docs/RUNBOOK.md`](docs/RUNBOOK.md) for the common-incident playbook (payment webhook didn't fire, inventory oversold, user can't login, Firestore rule denied, Cloud Function OOM). Each incident has: symptom, diagnosis, fix, rollback.

---

## Business-critical rules

These are enforced by the new `firestore.rules`, `storage.rules`, and the Cloud Functions trust boundary. They are non-negotiable:

1. **The client never computes money.** All totals, discounts, delivery fees come from a server-signed `PricingSnapshot` returned by `calcOrder`. The signature is re-verified inside `reserveStock` and `createOrder`.
2. **The client never assigns role.** Roles come from Firebase Custom Claims set by the backend (`provisionStaff`, `setUserRole`, `onUserCreate`). The client never writes `role`, `isBanned`, `points`, or `walletBalance`.
3. **Stock is reserved transactionally.** `reserveStock` performs a Firestore transaction that atomically decrements `stock` and increments `reservedStock`. Reservations expire after 15 minutes; `releaseReservation` reverses them. `commitReservation` finalizes them when the order is confirmed.
4. **Payments are verified via webhook + re-query.** Every gateway payment triggers a server-side webhook AND a scheduled re-query (`verifyPayment`) — the order is only marked paid when both agree. The client polls `verifyPayment` every 3s for up to 2 minutes after redirect.
5. **Every privileged action is audit-logged.** `auditLogs/{logId}` records who, what, when, before, after, for every admin/staff action. The collection is admin-only read; client writes are denied.

---

## Contributing

1. Read `docs/ARCHITECTURE.md` and `docs/SECURITY.md` first — the trust boundary is non-obvious.
2. Open a draft PR early so CI can run rules-tests and analyze on your branch.
3. All Dart code must pass `flutter analyze --fatal-infos --fatal-warnings`.
4. All TypeScript code must pass `npm run lint && npx tsc --noEmit`.
5. Never commit `.env`, `google-services.json`, `GoogleService-Info.plist`, `keystore.properties`, or any `service-account-*.json`. The `.gitignore` and CI security scans enforce this.
6. If you change `firestore.rules` or `storage.rules`, you MUST add a corresponding test under `test/firestore_rules/`.
7. If you change money / inventory / payment logic, the change must be in `functions/src/`, not in `lib/`.

---

## License

Proprietary — © Paykari Bazar. All rights reserved. See `LICENSE` (to be added) for the full text. Third-party product data under `assets/main-store-structure/` has separate provenance and usage restrictions — see `docs/DATA_PROVENANCE.md` before any commercial use.
