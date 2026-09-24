# Cloud Functions Deploy Checklist

Pre-flight checklist for deploying `functions/` to **production**. Run through every item before triggering the `functions-deploy.yml` workflow with `environment=production`.

> Staging deploys auto-trigger on push to `main` and skip the manual items (5, 9, 11, 13, 16).

---

## 1. Code readiness

- [ ] `cd functions && npm run lint` passes (zero eslint warnings)
- [ ] `cd functions && npx tsc --noEmit` passes (zero TypeScript errors)
- [ ] `cd functions && npm test` passes (all unit tests green)
- [ ] `cd functions && npm run build` produces `functions/lib/index.js` with no errors
- [ ] PR has at least one reviewer approval
- [ ] PR is up to date with `main` (no merge conflicts)

## 2. Code review focus

- [ ] No new `console.log` (use the structured logger instead)
- [ ] No new `any` TypeScript types in exported functions
- [ ] No new direct Firestore `.set()` / `.update()` outside a transaction (for money / inventory / payment)
- [ ] No new `process.env.SECRET_NAME` reads without a corresponding entry in `functions/.env.example`
- [ ] No new `onCall` without `assertRole(...)` AND `assertAppCheck()`
- [ ] No new `onRequest` (HTTP webhook) without signature verification
- [ ] New callable has a docstring matching the format in existing callables
- [ ] New callable is registered in `functions/src/index.ts`

## 3. Region

- [ ] All new callables use `{ region: 'asia-southeast1' }` (matches Firebase project region)
- [ ] All new HTTP webhooks use `{ region: 'asia-southeast1', invoker: 'public' }` (webhooks must be public so the gateway can reach them)

## 4. Workload Identity Federation

- [ ] GitHub Secrets `GCP_FUNCTIONS_WIF_PROVIDER` and `GCP_FUNCTIONS_SERVICE_ACCOUNT` are set
- [ ] The WIF pool's `attribute.repository` matches `paykaribazar/paykaribazar` (or your org/repo)
- [ ] The service account has `roles/cloudfunctions.developer` and `roles/firebaserules.admin`
- [ ] The service account has `roles/iam.serviceAccountUser` on itself (for impersonation)

## 5. Secrets

- [ ] All secrets listed in `functions/.env.example` are set in Google Secret Manager for the production project
- [ ] `firebase functions:secrets:access BKASH_APP_KEY --project=paykari-prod` returns the expected value
- [ ] Same for `BKASH_APP_SECRET`, `BKASH_USERNAME`, `BKASH_PASSWORD`
- [ ] Same for `NAGAD_MERCHANT_ID`, `NAGAD_PUBLIC_KEY`, `NAGAD_PRIVATE_KEY`
- [ ] Same for `SSLCOMMERZ_STORE_ID`, `SSLCOMMERZ_STORE_PASSWD`
- [ ] Same for `GEMINI_API_KEY`, `PRICING_HMAC_SECRET`, `SLACK_WEBHOOK_URL`, `SENTRY_DSN_FUNCTIONS`
- [ ] `BANK_ACCOUNTS_JSON` is set and points to production bank accounts
- [ ] Secret rotation date is logged in `docs/CHANGELOG-PRODUCTION-PATCH.md` under "Security rotations"

## 6. Environment variables (non-secret)

- [ ] `BKASH_BASE_URL` is set to `https://tokenized.pay.bka.sh/v1.2.0-beta` (NOT sandbox)
- [ ] `NAGAD_BASE_URL` is set to `https://api.mynagad.com/api/dfs` (NOT sandbox)
- [ ] `SSLCOMMERZ_BASE_URL` is set to `https://securepay.sslcommerz.com/gwprocess/v4/api.php` (NOT sandbox)
- [ ] `BKASH_CALLBACK_URL` is `https://asia-southeast1-paykari-prod.cloudfunctions.net/bkashWebhook`
- [ ] `NAGAD_CALLBACK_URL` is `https://asia-southeast1-paykari-prod.cloudfunctions.net/nagadWebhook`
- [ ] `SSLCOMMERZ_IPN_URL` is `https://asia-southeast1-paykari-prod.cloudfunctions.net/sslcommerzWebhook`

## 7. Firebase project

- [ ] `firebase use production` is selected (or `--project=paykari-prod` is passed)
- [ ] `firebase use` reports the production alias
- [ ] The Firestore database region is `asia-southeast1`
- [ ] The Cloud Storage bucket region is `asia-southeast1`

## 8. Firestore indexes

- [ ] `firestore.indexes.json` is up to date with any new composite indexes
- [ ] `firebase deploy --only firestore:indexes --project=paykari-prod` has been run for the current `firestore.indexes.json`
- [ ] All indexes report `READY` in Firebase Console → Firestore → Indexes (no `BUILDING` state)

## 9. Webhook registration (gateway dashboards)

- [ ] bKash merchant portal → Webhook Configuration → URL is `https://asia-southeast1-paykari-prod.cloudfunctions.net/bkashWebhook`
- [ ] Nagad merchant portal → API Configuration → URL is `https://asia-southeast1-paykari-prod.cloudfunctions.net/nagadWebhook`
- [ ] SSLCommerz merchant portal → Store Profile → IPN → URL is `https://asia-southeast1-paykari-prod.cloudfunctions.net/sslcommerzWebhook`

## 10. App Check

- [ ] Production Android app package name (`com.njel.paykari_bazar`) is registered in Firebase Console → App Check
- [ ] Play Integrity provider is enabled and enforced
- [ ] All Cloud Functions have `assertAppCheck()` in their entry (CI lint catches missing assertions)

## 11. Smoke test on staging

- [ ] The same code has been deployed to staging
- [ ] Customer app on staging: login → browse → cart → checkout with bKash sandbox → confirm `payments/{id}.status == success`
- [ ] Same for Nagad sandbox
- [ ] Same for SSLCommerz sandbox
- [ ] Same for bank transfer (slip upload + manual verification)
- [ ] Admin app on staging: view the orders from above → confirm `status == paid`
- [ ] `firebase emulators:exec --only firestore,storage "dart test test/firestore_rules/"` passes against the staging rules
- [ ] `auditLogs` contains entries for every test action

## 12. Rollback plan

- [ ] Previous Cloud Functions SHA is identified (`git rev-parse HEAD~1`)
- [ ] Previous `firestore.rules` and `storage.rules` SHA is identified
- [ ] Rollback commands are documented:
  ```bash
  # Functions
  firebase functions:rollback --project=paykari-prod
  # OR pin to previous SHA:
  git checkout <prev-sha> -- functions/
  (cd functions && npm ci && npm run build && firebase deploy --only functions --project=paykari-prod)
  # Rules
  git checkout <prev-sha> -- firestore.rules storage.rules
  firebase deploy --only firestore:rules,storage:rules --project=paykari-prod
  ```
- [ ] On-call engineer is paged and aware of the deploy window

## 13. Notify stakeholders

- [ ] `#incidents` Slack channel notified of the deploy window
- [ ] Customer support team notified (in case of payment issues)
- [ ] SRE on-call acknowledged the deploy

## 14. Trigger the deploy

- [ ] Open GitHub → Actions → `functions-deploy` → Run workflow → `environment=production`
- [ ] SRE reviewer approves the production environment gate
- [ ] Watch the workflow run to completion (lint → typecheck → unit-test → deploy)
- [ ] Verify in Firebase Console → Functions that all functions show the latest SHA

## 15. Post-deploy verification

- [ ] Production smoke test (same as staging smoke test, but on production with sandbox credentials — see `docs/RUNBOOK.md` § 1 for the recovery flow if a webhook fails)
- [ ] `auditLogs` is receiving entries (do a test order)
- [ ] bKash/Nagad/SSLCommerz webhooks are reachable (test from the gateway dashboard)
- [ ] Sentry is receiving errors (force a test error from a dev build pointing at production)
- [ ] Slack `#incidents` is silent for 15 minutes after deploy

## 16. Documentation

- [ ] `docs/CHANGELOG-PRODUCTION-PATCH.md` updated with the deploy date + SHA + summary of changes
- [ ] If any secret was rotated, log it under "Security rotations" with date + secret + reason
- [ ] If any new incident pattern emerged during the deploy, add a runbook entry to `docs/RUNBOOK.md`

---

## Quick reference: deploy command

```bash
# Trigger via GitHub Actions (preferred)
# Open GitHub → Actions → functions-deploy → Run workflow → environment=production

# Manual fallback (only if GitHub Actions is down)
firebase use production
cd functions
npm ci
npm run build

# Deploy order: callables → webhooks → triggers
firebase deploy --only functions:calcOrder,functions:reserveStock,functions:releaseReservation,functions:commitReservation,functions:createOrder,functions:cancelOrder,functions:verifyPayment,functions:refundPayment,functions:bkashCreatePayment,functions:nagadCreatePayment,functions:sslczCreatePayment,functions:recordBankPaymentRequest,functions:searchProducts,functions:redeemCoupon,functions:setUserRole,functions:provisionStaff,functions:seedLocations,functions:analyzePrescription --project=paykari-prod --force

firebase deploy --only functions:bkashWebhook,functions:nagadWebhook,functions:sslcommerzWebhook --project=paykari-prod --force

firebase deploy --only functions:onUserCreate --project=paykari-prod --force

firebase deploy --only firestore:rules,firestore:indexes,storage:rules --project=paykari-prod
```
