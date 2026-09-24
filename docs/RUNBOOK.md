# Runbook — Incident Handling

This is the on-call runbook for Paykari Bazar production incidents. Each entry follows the format:

> **Symptom** — what the on-call engineer sees
> **Diagnosis** — how to confirm the root cause
> **Fix** — the concrete steps to mitigate
> **Rollback** — how to undo the fix if it makes things worse

Severity definitions and the incident process are in [`SECURITY.md` § 9](./SECURITY.md#9-incident-response). If you can't find a runbook here, **improvise but write a new one as you go**.

---

## 1. Payment webhook didn't fire

### Symptom

- Customer reports they paid via bKash/Nagad/SSLCommerz but the order is still `pending_payment`.
- `payments/{id}.status == 'initiated'` after 10+ minutes.
- `auditLogs` shows no `PAYMENT_SUCCESS` entry.

### Diagnosis

1. Check if the gateway actually accepted the payment:
   - bKash: log in to sandbox/production bKash merchant portal → search by `paymentID` → check status.
   - Nagad: similar, search by `payment_reference_id`.
   - SSLCommerz: search by `tran_id`.
2. Check Cloud Functions logs: `firebase functions:log --only bkashWebhook --project=$PROJECT_ID` (or `nagadWebhook` / `sslcommerzWebhook`).
   - If the webhook fired but errored, the error is in the logs.
   - If the webhook never fired, the gateway's webhook URL is misconfigured.
3. Check `payments/{id}.webhookPayload` — if it's null, the webhook never reached us.

### Fix

1. If the gateway reports `success` but we never marked the payment, manually trigger `verifyPayment`:
   ```bash
   # From a Firebase Functions shell (or curl the callable):
   firebase functions:shell --project=$PROJECT_ID
   > verifyPayment({ paymentId: "<paymentId>" })
   ```
2. If `verifyPayment` succeeds, `payments.status` becomes `success` and `orders.status` becomes `paid`. Notify the customer in-app.
3. If `verifyPayment` fails (gateway now says `failed`):
   - Mark `payments.status = failed` via the admin console.
   - Release the inventory reservation: `releaseReservation({ reservationId, reason: "payment failed" })`.
   - Refund if the gateway debited the customer (see [§ 8](#8-customer-requests-refund) below).
4. If the gateway's webhook URL is misconfigured, fix it in the gateway dashboard and re-test with a small sandbox order.

### Rollback

If you accidentally marked the wrong payment as `success`:

```bash
firebase functions:shell --project=$PROJECT_ID
> adminUpdatePayment({ paymentId, status: "initiated", reason: "wrong manual verify" })
```

This reverts `payments.status` and `orders.status` back to `pending_payment`. Document the rollback in `auditLogs` (the callable does this automatically).

---

## 2. Inventory oversold

### Symptom

- `products/{id}.stock` is `0` but orders are still being placed.
- `products/{id}.soldStock` exceeds `products/{id}.originalStock`.
- Customer reports ordering an item that was out of stock.

### Diagnosis

1. Run the reconciliation query:
   ```
   SELECT productId, SUM(qty) AS reserved
   FROM inventoryReservations
   WHERE status = 'active' OR status = 'committed'
   GROUP BY productId
   ```
   Compare against `products.stock` + `products.reservedStock`.
2. Look for `inventoryReservations` with `expiresAt < now` AND `status = 'active'` — the TTL cron failed.
3. Look at `auditLogs` for `STOCK_ADJUST` entries — someone manually overrode stock.

### Fix

1. Stop new orders: in Firebase Console, set `products/{id}.stock = 0` and `products/{id}.availability = 'out_of_stock'`.
2. For each affected order:
   - If the order hasn't been dispatched, cancel it: `cancelOrder({ orderId, reason: "out of stock" })`. This releases the reservation and refunds the customer (if paid).
   - If the order has been dispatched, mark as `short_shipped` (manual) and notify the customer; offer a refund or reshipment.
3. Run the reconciliation cron manually:
   ```bash
   firebase functions:shell --project=$PROJECT_ID
   > reconcileInventory({ productId: "<productId>" })
   ```
4. Investigate the root cause:
   - If a `reserveStock` transaction failed silently, check `functions:log` for Firestore transaction errors.
   - If the TTL cron didn't fire, check Cloud Scheduler → confirm the job exists and is enabled.
   - If a staff member overrode stock, add a policy guard: `STOCK_ADJUST` should require `assertRole(['admin'])` AND a `reason` field ≥ 20 chars.

### Rollback

If you accidentally cancelled an order that should have shipped:

```bash
firebase functions:shell --project=$PROJECT_ID
> adminUpdateOrder({ orderId, status: "confirmed" })
```

Then notify the customer that the cancellation was reverted.

---

## 3. User can't login (custom claims missing)

### Symptom

- Customer signs up successfully but the admin console shows no `role`.
- Staff member reports "I'm a staff member but I can't see the admin panel" — `request.auth.token.role != 'staff'`.
- Sign-up completes but `users/{uid}.role` is null.

### Diagnosis

1. Check Auth → user exists, has email verified.
2. Check Firestore → `users/{uid}` document — does it exist? Does it have `role` set?
3. Check `auditLogs` for `onUserCreate` failures.
4. Check Cloud Functions logs → `firebase functions:log --only onUserCreate --project=$PROJECT_ID`.
   - If `onUserCreate` errored, the Firestore profile wasn't created.
5. For staff: check if `provisionStaff` was called. Look at `auditLogs` for `ROLE_PROVISION` entries for this user.

### Fix

1. **For a customer with no profile**: the `onUserCreate` trigger failed. Manually re-run it:
   ```bash
   firebase functions:shell --project=$PROJECT_ID
   > onUserCreate({ uid: "<uid>" })  # manually invoke
   ```
   Or directly create the doc:
   ```bash
   firebase firestore:write users/<uid> --data='{"role":"customer","points":0,"walletBalance":0,"createdAt":"<serverTimestamp>"}'
   ```

2. **For a staff member with no claim**: the admin who provisioned them needs to call `provisionStaff` again:
   ```bash
   firebase functions:shell --project=$PROJECT_ID
   > provisionStaff({ uid: "<uid>", role: "staff" })
   ```
   This sets the custom claim AND the Firestore doc field. The user must then sign out + sign in to refresh their ID token (claims are embedded in the JWT).

3. **Verify** the claim:
   ```bash
   firebase auth:print-config <uid>
   # Look for "customClaims": { "role": "staff", "staff": true, ... }
   ```

### Rollback

If you accidentally escalated a user to admin:

```bash
firebase functions:shell --project=$PROJECT_ID
> setUserRole({ uid: "<uid>", role: "customer" })
```

This downgrades the claim and the doc. File a SEV-1 post-mortem if the escalation was unauthorized.

---

## 4. Firestore rule denied

### Symptom

- Client logs `FirebaseException: Missing or insufficient permissions` on a Firestore read/write.
- Customer can't add an item to wishlist.
- Admin can't view an order.

### Diagnosis

1. Note the exact collection path and the action (read/write/create/update/delete).
2. Look at the rules test suite — does a test exist for this case?
3. If the rules were recently changed, check `auditLogs` for `RULES_DEPLOY`.
4. Use the Firestore Rules Playground in the Firebase Console:
   - Console → Firestore → Rules → "Rules Playground" tab
   - Simulate the request as the affected user with their auth context.
5. Check `request.auth.token` (claims) — is the user's role claim set correctly? (See [§ 3](#3-user-cant-login-custom-claims-missing) if claims are missing.)

### Fix

1. **If the rule is wrong** (e.g. it allows too little): fix `firestore.rules`, add a test in `test/firestore_rules/`, deploy.
2. **If the rule is right but the user lacks a claim**: provision the claim (see [§ 3](#3-user-cant-login-custom-claims-missing)).
3. **If the rule is right but the data is malformed** (e.g. user is trying to write `role: 'admin'` from the client): the denial is correct — investigate why the client is attempting the write. Likely a code bug; fix in the client.
4. **If the rule denies because of a missing `exists()` check** (e.g. `exists(/databases/.../businesses/$(request.resource.data.businessId))` and the business doc doesn't exist): create the business doc via `provisionStaff` or the admin console.

### Rollback

If you deployed a rule change that broke production:

```bash
git checkout <previous-sha> -- firestore.rules
firebase deploy --only firestore:rules --project=$PROJECT_ID
```

Then add a regression test for the case that the new rule broke.

---

## 5. Cloud Function OOM

### Symptom

- Cloud Function crashes with `Error: memory limit exceeded`.
- Cloud Monitoring shows the function's memory usage spiking before the crash.
- Customer reports intermittent failures (some requests succeed, some fail).

### Diagnosis

1. `firebase functions:log --only <functionName> --project=$PROJECT_ID` → look for `memory limit exceeded` entries.
2. Cloud Monitoring → Cloud Functions → `<functionName>` → Memory → check the peak.
3. Identify the input that triggered the spike:
   - `createOrder` with a large cart (100+ items)?
   - `analyzePrescription` with a very large image?
   - `searchProducts` with a wildcard query that returns too many docs?

### Fix

1. **Immediate**: increase the function's memory limit in `functions/src/index.ts`:
   ```typescript
   export const createOrder = onCall(
     { region: 'asia-southeast1', memory: '1GiB' },
     async (req) => { ... }
   );
   ```
   Redeploy.
2. **Root cause**: usually it's a N+1 query (looping `get()` calls) or loading an entire collection into memory.
   - For `createOrder`: batch reads; use `Firestore.getAll(refs...)`.
   - For `analyzePrescription`: cap the image size at the callable entry (e.g. `if (imageBytes.length > 4_000_000) throw new HttpsError('failed-precondition', 'Image too large')`).
   - For `searchProducts`: enforce a `limit` parameter, default 20, max 100.
3. **Add a memory budget**: wrap the hot path in a `Promise` that rejects if RSS exceeds 80% of the function's memory limit. Log the rejected input.

### Rollback

If increasing memory didn't help (or you hit the function-memory ceiling of 8 GiB), roll back to the previous function version:

```bash
firebase functions:rollback --only <functionName> --project=$PROJECT_ID
```

Then ship a hotfix that addresses the root cause.

---

## 6. Cloud Function cold start timeout

### Symptom

- First request after a deploy takes 10+ seconds and the client times out.
- Subsequent requests are fast.

### Diagnosis

1. Cloud Monitoring → Cloud Functions → `<functionName>` → "Execution time" → look at the cold-start latency.
2. Check `firebase functions:log` for `Function execution took X ms` on cold starts.
3. Identify heavy module-load work: `require('firebase-admin')` is OK; `require('@google/generative-ai')` (Gemini SDK) is heavy.

### Fix

1. **Minimize top-level imports**: move heavy imports inside the function body (lazy require):
   ```typescript
   export const analyzePrescription = onCall({ region: 'asia-southeast1' }, async (req) => {
     const { GoogleGenerativeAI } = await import('@google/generative-ai');  // lazy
     // ...
   });
   ```
2. **Increase the function's timeout** (only if cold start is unavoidable):
   ```typescript
   export const analyzePrescription = onCall(
     { region: 'asia-southeast1', timeoutSeconds: 60 },
     async (req) => { ... }
   );
   ```
3. **Set `minInstances: 1`** to keep a warm instance (costs ~$5/mo/function but eliminates cold starts):
   ```typescript
   export const createOrder = onCall(
     { region: 'asia-southeast1', minInstances: 1 },
     async (req) => { ... }
   );
   ```

### Rollback

Cold-start latency is rarely fixed by rolling back. If a deploy introduced a much heavier import, roll back the deploy and refactor.

---

## 7. Customer reports double charge

### Symptom

- Customer says they were charged twice for one order.
- `payments/{id}` shows two records with the same `gatewayTrxId`.

### Diagnosis

1. Look at `payments` where `orderId == <orderId>` — how many?
2. Look at `auditLogs` for `PAYMENT_INITIATE` entries on this order.
3. Check the gateway dashboard — does it show one or two transactions?
4. Check `bkashCreatePayment` (or equivalent) — did the customer tap "Pay" twice? (See [idempotency](../docs/PAYMENTS.md#9-idempotency-design) — the create-payment callable should be idempotent on `orderId`.)

### Fix

1. Confirm only one of the two `payments` records is `success`; the other should be `cancelled` or `failed`.
2. If both are `success`, refund the duplicate:
   ```bash
   firebase functions:shell --project=$PROJECT_ID
   > refundPayment({ paymentId: "<duplicatePaymentId>", amountPoisha: <amount>, reason: "duplicate charge" })
   ```
3. Investigate why the create-payment callable wasn't idempotent. Likely a missing index on `payments.orderId + status`. Check `firestore.indexes.json`.

### Rollback

Refunds are themselves immutable. If the refund was wrong (e.g. you refunded the wrong payment), file a SEV-1 and contact the gateway support to reverse the refund.

---

## 8. Customer requests refund

### Symptom

- Customer emails / chats requesting a refund.
- Order is `paid` and possibly `dispatched`/`delivered`.

### Diagnosis

1. Open the order in the admin console → confirm `status == 'paid'` (or `dispatched`/`delivered`).
2. Check `payments/{id}.status == 'success'`.
3. Confirm the refund is within policy: 30 days for full refund, no questions asked; 30-90 days for partial refund at admin discretion; > 90 days contact support.

### Fix

1. Admin opens the order → clicks "Refund".
2. Admin enters the refund amount (full or partial) and a reason.
3. `refundPayment` callable:
   - Calls the gateway's refund API.
   - Updates `payments.refund`.
   - Updates `orders.status` to `refunded` (full) or `partially_refunded` (partial).
   - Writes `auditLogs`.
4. Customer receives an in-app notification + the wallet/bank credit lands within 3 business days.

### Rollback

Refunds are immutable. If the refund was unauthorized, contact the gateway support to reverse it. Document the unauthorized refund as a SEV-1.

---

## 9. Firestore indexes missing

### Symptom

- Client logs `FirebaseException: The query requires an index`.
- The error message includes a link to create the index in the Firebase Console.

### Diagnosis

1. The error message tells you exactly what index is missing.
2. Check `firestore.indexes.json` — is it in there? If yes, the deploy didn't include it; redeploy: `firebase deploy --only firestore:indexes`.
3. If it's not in the file, add it.

### Fix

1. Add the index to `firestore.indexes.json`:
   ```json
   {
     "indexes": [
       {
         "collectionGroup": "orders",
         "queryScope": "COLLECTION",
         "fields": [
           { "fieldPath": "userId", "order": "ASCENDING" },
           { "fieldPath": "createdAt", "order": "DESCENDING" }
         ]
       }
     ]
   }
   ```
2. Deploy: `firebase deploy --only firestore:indexes --project=$PROJECT_ID`.
3. Wait for the index to build (can take 5-30 minutes depending on collection size).

### Rollback

Indexes are not destructive. If you added an index that's no longer needed, delete it from the JSON and redeploy.

---

## 10. App Check failures

### Symptom

- Cloud Function callable returns `UNAUTHENTICATED` even though the user is logged in.
- Error message in `firebase functions:log`: `App Check token verification failed`.

### Diagnosis

1. Confirm the client is passing an App Check token (debug or Play Integrity).
2. Confirm the App Check provider is registered in the Firebase Console → App Check.
3. For development: confirm the debug token is set in the Flutter app's `main()`:
   ```dart
   await FirebaseAppCheck.instance.activate(
     androidProvider: AndroidProvider.debug,
     // webProvider: ReCaptchaV3Provider('...'),
   );
   ```
4. For production: confirm Play Integrity is enabled in the Console → App Check → Apps.

### Fix

1. Re-register the App Check debug token: `firebase appcheck:debug:new-token` in the dev terminal.
2. For production, confirm the Play Integrity provider is enabled for the Android app package name (`com.njel.paykari_bazar`).
3. If enforcement is broken, temporarily disable enforcement in Console → App Check → "Enforce" toggle. **This is a security regression** — re-enable as soon as the issue is fixed.

### Rollback

App Check enforcement can be toggled in the Console. Re-enabling is the rollback; disabling is the regression.

---

## 11. Slack / Sentry silent

### Symptom

- No alerts on Slack `#incidents` channel even though an incident is happening.
- Sentry shows no new errors.

### Diagnosis

1. Check Cloud Monitoring alerts → are they firing?
2. Check the Slack webhook URL — is it still valid?
3. Check the Sentry DSN — is it set in the client + functions?

### Fix

1. Re-register the Slack webhook URL in `functions/.env` + GitHub Secrets → redeploy.
2. Update the Sentry DSN in `lib/main_customer.dart`, `lib/main_admin.dart`, and `functions/.env`.
3. Trigger a test alert:
   ```bash
   curl -X POST -H 'Content-type: application/json' \
     --data '{"text":"test alert from runbook"}' \
     $SLACK_WEBHOOK_URL
   ```

### Rollback

No rollback needed — alerting is non-destructive.

---

## 12. Generic incident process (when no runbook matches)

1. **Page the on-call engineer** (PagerDuty / Opsgenie rotation).
2. **Open a Slack thread in `#incidents`** with the format `[SEV-X] <short description>`.
3. **Acknowledge** within the response time (SEV-1: immediate; SEV-2: < 1 hour).
4. **Mitigate**: do whatever stops the bleeding (rollback, disable feature flag, scale up, etc.). Don't worry about elegance.
5. **Document** every action as you take it — timestamps + commands — in the Slack thread.
6. **Resolve** when the system is back to normal.
7. **Post-mortem** within 48 hours for SEV-1/SEV-2: blameless, written up in `docs/postmortems/<YYYY-MM-DD>-<short-slug>.md`, with a "what went well / what went wrong / what to improve" section.
8. **Add a runbook** for the new failure mode in this file.
