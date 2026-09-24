# Deployment

This document is the step-by-step guide for deploying Paykari Bazar from development to staging to production.

For the CI/CD pipeline see `.github/workflows/` (especially `auto-build-and-deploy.yml`, `functions-deploy.yml`, `release.yml`). For the pre-flight checklist see [`../functions-deploy-checklist.md`](../functions-deploy-checklist.md).

---

## 0. Prerequisites

- **Flutter 3.27+**, **Node.js 20 LTS**, **Java 17**, **Firebase CLI** (`npm install -g firebase-tools`), **Google Cloud CLI** (`gcloud`).
- Three Firebase projects: `paykari-dev`, `paykari-staging`, `paykari-prod`.
- A Google Cloud project with Workload Identity Federation configured for GitHub Actions.
- Android release keystore + `keystore.properties` (stored as GitHub Actions secrets).
- Shorebird account + `SHOREBIRD_AUTH_TOKEN`.
- API credentials for bKash, Nagad, SSLCommerz (sandbox + production).
- A Gemini API key for server-side AI enrichment.

---

## 1. Local development

### Bootstrap

```bash
git clone <repo-url> paykari-bazar
cd paykari-bazar
flutter pub get
cd functions && npm ci && npm run build && cd ..
firebase use default
firebase emulators:start --only firestore,functions,auth,storage
```

### Run the apps

```bash
# Customer
flutter run -t lib/main_customer.dart --flavor customer

# Admin
flutter run -t lib/main_admin.dart --flavor admin
```

### Run the rules tests

```bash
firebase emulators:exec --only firestore,storage "dart test test/firestore_rules/"
```

### Run the integration tests

```bash
firebase emulators:exec --only firestore,functions,auth,storage \
  "flutter test integration_test/"
```

---

## 2. Firebase project setup

Each environment (dev / staging / production) needs:

### 2.1 Authentication providers

Enable in Firebase Console → Authentication → Sign-in method:

- Email/Password
- Phone
- Google (with Web SDK configuration)
- (Optional) Facebook

### 2.2 Firestore

- Create the database in **`asia-southeast1`** (matches the Cloud Functions region).
- Enable in production mode (rules default-deny).
- Deploy rules: `firebase deploy --only firestore:rules`.
- Deploy indexes: `firebase deploy --only firestore:indexes` (from `firestore.indexes.json`).

### 2.3 Cloud Storage

- Create the bucket in **`asia-southeast1`**.
- Deploy rules: `firebase deploy --only storage`.

### 2.4 App Check

- Register the Android app(s) with the Play Integrity provider.
- For development, register a debug token: `firebase appcheck:debug:new-token`.
- Enforce App Check on Cloud Functions (`assertAppCheck()` is already in `functions/src/shared/security.ts`).

### 2.5 Cloud Functions

- Set the region to `asia-southeast1` (already in all `onCall({ region: 'asia-southeast1' }, ...)`).
- Set the secret env vars (see `docs/SECURITY.md` § 3):
  ```bash
  firebase functions:secrets:set BKASH_APP_KEY
  firebase functions:secrets:set BKASH_APP_SECRET
  # ... all secrets from functions/.env.example
  ```
- Deploy order (see `.github/workflows/functions-deploy.yml`):
  1. Callable Cloud Functions (calcOrder, reserveStock, createOrder, verifyPayment, ...)
  2. Webhook HTTP Functions (bkashWebhook, nagadWebhook, sslcommerzWebhook)
  3. Firestore trigger Functions (onUserCreate)

### 2.6 Firebase Hosting

Configure `firebase.json` with two hosting targets:

```json
{
  "hosting": [
    { "target": "customer", "public": "build/web_customer", "ignore": ["firebase.json", "**/.*", "**/node_modules/**"] },
    { "target": "admin",    "public": "build/web_admin",    "ignore": ["firebase.json", "**/.*", "**/node_modules/**"] }
  ]
}
```

---

## 3. Workload Identity Federation (WIF)

GitHub Actions uses Workload Identity Federation to impersonate a Google Cloud service account — no long-lived JSON key file is needed.

### 3.1 Create the WIF pool + provider

```bash
# One-time setup (run by the GCP project owner)
gcloud iam workload-identity-pools create paykari-github \
  --location=global \
  --display-name="Paykari GitHub Actions Pool"

gcloud iam workload-identity-pools providers create-oidc paykari-github-provider \
  --location=global \
  --workload-identity-pool=paykari-github \
  --display-name="Paykari GitHub Actions OIDC Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
  --issuer-uri="https://token.actions.githubusercontent.com"
```

### 3.2 Create the service account

```bash
gcloud iam service-accounts create paykari-functions-deployer \
  --display-name="Paykari Cloud Functions Deployer"

# Grant Cloud Functions deployer role
gcloud projects add-iam-policy-binding paykari-prod \
  --member="serviceAccount:paykari-functions-deployer@paykari-prod.iam.gserviceaccount.com" \
  --role="roles/cloudfunctions.developer"

# Grant Firebase Admin (for Firestore rules deploy)
gcloud projects add-iam-policy-binding paykari-prod \
  --member="serviceAccount:paykari-functions-deployer@paykari-prod.iam.gserviceaccount.com" \
  --role="roles/firebaserules.admin"

# Allow the WIF provider to impersonate the SA
gcloud iam service-accounts add-iam-policy-binding \
  paykari-functions-deployer@paykari-prod.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/<PROJ-NUM>/locations/global/workloadIdentityPools/paykari-github/attribute.repository/paykaribazar/paykaribazar"
```

### 3.3 Store in GitHub Secrets

| Secret                          | Value |
| ------------------------------- | ----- |
| `GCP_FUNCTIONS_WIF_PROVIDER`    | `projects/<PROJ-NUM>/locations/global/workloadIdentityPools/paykari-github/providers/paykari-github-provider` |
| `GCP_FUNCTIONS_SERVICE_ACCOUNT` | `paykari-functions-deployer@paykari-prod.iam.gserviceaccount.com` |

### 3.4 Verify

Run the `functions-deploy.yml` workflow with `environment=staging` and verify the OIDC auth step succeeds.

---

## 4. Cloud Function deploy order

The `functions-deploy.yml` workflow enforces this order:

### Step 1: Callable Cloud Functions

These are the user-facing callables. Deploy first so the client can always reach them.

```bash
firebase deploy --only functions:calcOrder,functions:reserveStock,functions:releaseReservation,functions:commitReservation,functions:createOrder,functions:cancelOrder,functions:verifyPayment,functions:refundPayment,functions:bkashCreatePayment,functions:nagadCreatePayment,functions:sslczCreatePayment,functions:recordBankPaymentRequest,functions:searchProducts,functions:redeemCoupon,functions:setUserRole,functions:provisionStaff,functions:seedLocations,functions:analyzePrescription \
  --project=$PROJECT_ID --force
```

### Step 2: Webhook HTTP Functions

These receive callbacks from payment gateways. Deploy second so they exist before the gateways start sending webhooks.

```bash
firebase deploy --only functions:bkashWebhook,functions:nagadWebhook,functions:sslcommerzWebhook \
  --project=$PROJECT_ID --force
```

### Step 3: Firestore Trigger Functions

These fire on Firestore writes. Deploy last so they don't fire on stale data during the transition.

```bash
firebase deploy --only functions:onUserCreate \
  --project=$PROJECT_ID --force
```

### Step 4: Firestore + Storage rules

```bash
firebase deploy --only firestore:rules,storage:rules --project=$PROJECT_ID
```

### Step 5: Firestore indexes

```bash
firebase deploy --only firestore:indexes --project=$PROJECT_ID
```

---

## 5. Flutter app deployment

### 5.1 Shorebird (OTA patches — instant)

The `auto-build-and-deploy.yml` workflow deploys Shorebird patches on every push to `main`. Patching is preferred over full releases for non-native changes.

```bash
shorebird patch android --flavor customer -t lib/main_customer.dart
shorebird patch android --flavor admin    -t lib/main_admin.dart
```

### 5.2 Android APK / AAB (full releases)

The `release.yml` workflow builds full APKs on tag push (`vX.Y.Z`):

```bash
flutter build apk -t lib/main_customer.dart --release --no-shrink
flutter build apk -t lib/main_admin.dart    --release --no-shrink
```

For Play Store uploads (currently disabled, `if: false` in `release.yml`):

```bash
cd fastlane
fastlane supply --package_name com.njel.paykari_bazar \
  --aab ../build/app/outputs/bundle/release/app-release.aab \
  --track beta \
  --json_key metadata/service_account.json
```

### 5.3 iOS (future)

The `ios/` shell exists but the iOS pipeline is not implemented. To enable:

1. Provision an Apple Developer account.
2. Set up signing certificates.
3. Add a `deploy-app-store.yml` workflow using `fastlane match` + `fastlane gym`.
4. Add the iOS flavor to `android/app/build.gradle`'s `flavorDimensions` (already customer + admin; iOS would mirror).

### 5.4 Web (Firebase Hosting)

The `release.yml` workflow builds the web versions of both apps and deploys to Firebase Hosting:

```bash
flutter build web -t lib/main_customer.dart --release --output=build/web_customer
flutter build web -t lib/main_admin.dart    --release --output=build/web_admin
firebase deploy --only hosting:customer,hosting:admin --project=$PROJECT_ID
```

---

## 6. Staging deployment

The CI pipeline auto-deploys to staging on every push to `main`. The flow:

1. PR opened against `main`.
2. CI runs all gates (rules-test, functions-test, analyze, secrets, etc.).
3. PR merged → `main` branch updated.
4. `auto-build-and-deploy.yml` runs: builds APKs, web builds, deploys to Firebase staging.
5. `functions-deploy.yml` runs (auto on push to main): deploys callables → webhooks → triggers to staging.
6. Smoke test on staging (manual — see below).

### Staging smoke test

After every staging deploy, on-call engineer runs:

- [ ] Open the staging customer app → log in → browse catalog
- [ ] Add an item to cart → checkout with bKash sandbox → confirm `payments/{id}.status == success`
- [ ] Repeat for Nagad sandbox and SSLCommerz sandbox
- [ ] Open the staging admin app → log in → view the order from above → confirm `status == paid`
- [ ] Trigger `firebase emulators:exec --only firestore,storage "dart test test/firestore_rules/"` against staging rules
- [ ] Check `auditLogs` for the test actions

If any step fails, file a SEV-2 and roll back per [`RUNBOOK.md`](./RUNBOOK.md).

---

## 7. Production deployment

**Production deploys require manual dispatch + reviewer approval.**

### 7.1 Backend (Cloud Functions + rules)

1. Open the `Actions` tab in GitHub → `functions-deploy` workflow → `Run workflow`.
2. Select `environment: production`.
3. Click `Run workflow`.
4. GitHub requires a reviewer from the SRE team to approve (the `production` environment in repo Settings → Environments has required reviewers configured).
5. After approval, the workflow runs lint → typecheck → unit-test → deploy (callables → webhooks → triggers → rules).
6. Verify in production: open Firebase Console → Functions → confirm all functions are deployed to `asia-southeast1` with the latest SHA.
7. Run the production smoke test (same as staging smoke test, but on production with sandbox credentials).

### 7.2 Flutter app (production release)

1. Tag the commit: `git tag vX.Y.Z && git push origin vX.Y.Z`.
2. The `release.yml` workflow runs.
3. Pre-release checks pass (rules-test + functions-test + secret-scan + analyze).
4. `keystore.properties` is restored from secrets (the workflow refuses to build without it).
5. Customer + Admin APKs are built.
6. GitHub Release is created with the APKs attached.
7. Shorebird release is created for both apps.
8. (Future) Play Store upload via fastlane.

### 7.3 Production post-deploy checklist

- [ ] All Cloud Functions deployed with the latest SHA
- [ ] `firestore.rules` and `storage.rules` match the repo's version
- [ ] `auditLogs` is receiving entries (do a test order)
- [ ] bKash, Nagad, SSLCommerz webhooks are reachable (test from the gateway dashboard)
- [ ] Sentry is receiving errors (forced a test error)
- [ ] Slack `#incidents` is silent
- [ ] `docs/CHANGELOG-PRODUCTION-PATCH.md` is updated

---

## 8. Rollback

### Cloud Functions

```bash
firebase functions:rollback --project=$PROJECT_ID
# or pin to a previous SHA:
firebase deploy --only functions --project=$PROJECT_ID  # from a previous git checkout
```

### Firestore / Storage rules

```bash
git checkout <previous-sha> -- firestore.rules storage.rules
firebase deploy --only firestore:rules,storage:rules --project=$PROJECT_ID
```

### Flutter app

- **Shorebird patch (instant)**: `shorebird patch android --flavor customer -t lib/main_customer.dart` from the previous SHA.
- **Play Store (slow)**: `fastlane supply --track beta --rollback` (Play Console supports rollback to a previous release).
- **APK sideload**: distribute the previous APK from the GitHub Releases page.

---

## 9. Environment variable matrix

| Secret / env var              | Dev               | Staging                | Production            |
| ----------------------------- | ----------------- | ---------------------- | --------------------- |
| `FIREBASE_PROJECT_ID`         | paykari-dev       | paykari-staging        | paykari-prod          |
| `FIREBASE_TOKEN`              | (your local)      | staging GitHub secret  | production GitHub secret |
| bKash                         | sandbox creds     | sandbox creds          | production creds      |
| Nagad                         | sandbox creds     | sandbox creds          | production creds      |
| SSLCommerz                    | sandbox creds     | sandbox creds          | production creds      |
| Gemini API key                | dev key           | staging key            | production key        |
| `PRICING_HMAC_SECRET`         | dev secret        | staging secret         | production secret     |
| Slack webhook                 | `#dev-notifications` | `#staging-notifications` | `#incidents`        |

The same secret NAME is used across environments — only the VALUE differs. Configure in:
- GitHub Settings → Environments → `staging` / `production` (per-environment secrets)
- Google Secret Manager (per-project)

---

## 10. Appendix: Deploy commands cheat sheet

```bash
# Switch project
firebase use staging
firebase use production

# Deploy everything (backend)
firebase deploy --only functions,firestore:rules,firestore:indexes,storage:rules --project=$PROJECT_ID

# Deploy only Firestore rules
firebase deploy --only firestore:rules --project=$PROJECT_ID

# Rollback Cloud Functions to previous version
firebase functions:rollback --project=$PROJECT_ID

# Build & deploy Flutter web (customer)
flutter build web -t lib/main_customer.dart --release --output=build/web_customer
firebase deploy --only hosting:customer --project=$PROJECT_ID

# Shorebird patch
shorebird patch android --flavor customer -t lib/main_customer.dart

# Local emulator (full suite)
firebase emulators:start --only firestore,functions,auth,storage,pubsub

# Run rules tests
firebase emulators:exec --only firestore,storage "dart test test/firestore_rules/"

# Run integration tests
firebase emulators:exec --only firestore,functions,auth,storage "flutter test integration_test/"
```
