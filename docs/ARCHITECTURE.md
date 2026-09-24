# Architecture

This document is the canonical reference for the Paykari Bazar system architecture. It covers:

1. The trust boundary and the data flow across it
2. The collection-by-collection Firestore schema
3. The checkout state machine
4. The payment webhook lifecycle
5. The role provisioning flow

For security details see [`SECURITY.md`](./SECURITY.md). For payment integration details see [`PAYMENTS.md`](./PAYMENTS.md). For step-by-step deploy see [`DEPLOYMENT.md`](./DEPLOYMENT.md).

---

## 1. Trust boundary

The trust boundary is the Cloud Functions layer (`functions/src/`). Everything outside it — the Flutter app, the user's browser session, the user's FCM token, the URL params of a payment redirect — is **untrusted**.

```
┌───────────────────────────────────────────────────────────────────┐
│                       UNTRUSTED                                   │
│                                                                   │
│   Flutter customer app      Flutter admin app      Web browser   │
│        │                          │                      │       │
│        └──────────────────────────┴──────────────────────┘       │
│                                     │                             │
└─────────────────────────────────────┼─────────────────────────────┘
                                      │  Firebase Auth token + App Check
                                      │  (asserted identity, NOT trust)
                                      ▼
┌───────────────────────────────────────────────────────────────────┐
│                       TRUST BOUNDARY                              │
│                                                                   │
│   Cloud Functions (asia-southeast1)                              │
│     - assertRole(['admin','staff','reseller','rider'])           │
│     - assertAppCheck()                                            │
│     - re-verifies every money / inventory / payment decision      │
│     - HMAC signs every PricingSnapshot                           │
│                                                                   │
└─────────────────────────────────────┬─────────────────────────────┘
                                      │  Admin SDK (bypasses rules)
                                      ▼
┌───────────────────────────────────────────────────────────────────┐
│   Firestore + Cloud Storage  (rules deny client writes for       │
│   money / stock / role / payment / ledger fields)                │
└───────────────────────────────────────────────────────────────────┘
```

### Rules of the trust boundary

1. **Client → Server**: every mutation of money / inventory / payment / role routes through a Callable Cloud Function. The callable re-verifies identity (Auth), claims (App Check + custom claims), and data (re-prices the order, re-checks stock, re-queries the gateway).
2. **Server → Database**: Cloud Functions use the Firebase Admin SDK, which bypasses `firestore.rules` and `storage.rules`. They are the only code path that mutates `orders`, `payments`, `inventoryReservations`, `users/{uid}/transactions`, `auditLogs`, and the inventory/pricing keys on `products`.
3. **Client → Database**: clients can read what they're allowed to read (their own profile, their own orders, public catalog, public product prices) and can write only to a narrow set of non-authoritative fields (their display name, their wishlist, their addresses, their profile photo).
4. **Webhook → Server**: payment gateway webhooks are HTTP-triggered Cloud Functions that re-query the gateway API to confirm the webhook payload is genuine. Webhooks never trust the request body alone.
5. **Audit trail**: every privileged server action writes a record to `auditLogs/{logId}` before returning to the client.

---

## 2. Firestore schema (collection-by-collection)

### `users/{userId}`

| Field                | Type     | Owner-writable | Notes |
| -------------------- | -------- | -------------- | ----- |
| `uid`                | string   | no             | mirrors Auth UID |
| `email`              | string   | no             | from Auth |
| `displayName`        | string   | yes            | profile |
| `phone`              | string   | yes            | profile |
| `photoURL`           | string   | yes            | Storage URL |
| `role`               | string   | **server-only** | `customer` \| `reseller` \| `staff` \| `admin` \| `rider` — also in custom claims |
| `isBanned`           | bool     | **server-only** | blocks auth on next token refresh |
| `points`             | int      | **server-only** | loyalty ledger |
| `walletBalance`      | int (poisha) | **server-only** | wallet ledger |
| `loyaltyTier`        | string   | server-only    | derived from points |
| `businessId`         | string?  | server-only    | set by `provisionStaff` |
| `createdAt`          | timestamp | server-only   | set by `onUserCreate` |
| `lastLoginAt`        | timestamp | server-only   | updated by Cloud Function |

Subcollections:
- `users/{uid}/addresses/{addressId}` — owner-only
- `users/{uid}/wishlist/{productId}` — owner-only
- `users/{uid}/transactions/{txId}` — **server-only writes** (wallet/loyalty ledger). Client reads own.

### `businesses/{businessId}`

| Field                | Type     | Notes |
| -------------------- | -------- | ----- |
| `name`               | string   | legal entity name |
| `type`               | string   | `retailer` \| `pharmacy` \| `grocery` \| `restaurant` \| `wholesaler` |
| `ownerUid`           | string   | links to `users/{uid}` |
| `tradeLicenseNo`     | string   | verification |
| `creditLimitPoisha`  | int      | server-only, admin-set |
| `tier`               | string   | server-only, derived from order history |
| `createdAt`          | timestamp | server-only |

Rules: read = authed. create = owner. update = owner-or-staff. delete = admin.

### `hub/data/products/{productId}`

| Field                | Type      | Notes |
| -------------------- | --------- | ----- |
| `name`, `nameBn`     | string    | merchandising |
| `description`, `descriptionBn` | string | merchandising |
| `categoryName`       | string    | denormalized |
| `brand`              | string    |  |
| `unit`               | string    | `kg` \| `pc` \| `l` \| ... |
| `images`             | string[]  | Storage URLs |
| `seoTags`            | string[]  | merchandising |
| `aiOptimized`        | bool      | set by `smartEnrichProduct` (dev only) |
| `aiAuditPending`     | bool      |  |
| `stock`              | int       | **server-only** — managed by `reserveStock`/`commitReservation` |
| `reservedStock`      | int       | **server-only** |
| `soldStock`          | int       | **server-only** |
| `wholesalePrice`     | int (poisha) | **server-only** — moved to `productPrices` |
| `tieredPrices`       | map       | **server-only** — moved to `productPrices` |
| `createdAt`, `updatedAt` | timestamp | server |

Rules: read = `true`. write = `isAdmin()` OR `isReseller()` — but `affectedKeys().hasAny([stock, reservedStock, wholesalePrice, tieredPrices])` returns false even for resellers (server-only).

### `hub/data/productPrices/{productId}` — NEW (canonical pricing)

Server-only ledger. The `calcOrder` callable reads from here to compute the signed `PricingSnapshot`.

| Field                | Type     | Notes |
| -------------------- | -------- | ----- |
| `wholesalePricePoisha` | int     | base price |
| `tieredPrices`       | map<businessType, int> | per-segment price |
| `mrpPoisha`          | int      | retail ceiling |
| `discountPoisha`     | int      | active discount |
| `validFrom`, `validUntil` | timestamp |  |
| `hmacSignature`      | string   | signs the snapshot returned by `calcOrder` |
| `lastUpdatedBy`      | string   | uid |
| `lastUpdatedAt`      | timestamp |  |

Rules: read = `true`. write = `isAdmin()` only.

### `inventoryReservations/{reservationId}` — NEW (transactional stock hold)

Server-only. Created by `reserveStock`, released by `releaseReservation`, finalized by `commitReservation`. Auto-expires after 15 minutes via a TTL trigger.

| Field                | Type     | Notes |
| -------------------- | -------- | ----- |
| `userId`             | string   |  |
| `businessId`         | string   |  |
| `items`              | array<{productId, qty, unitPricePoisha, lineTotalPoisha}> |  |
| `subtotalPoisha`     | int      |  |
| `deliveryFeePoisha`  | int      |  |
| `discountPoisha`     | int      |  |
| `totalPoisha`        | int      |  |
| `pricingSnapshot`    | map      | signed snapshot from `calcOrder` |
| `pricingSignature`   | string   | HMAC of `pricingSnapshot` |
| `status`             | string   | `active` \| `released` \| `committed` \| `expired` |
| `expiresAt`          | timestamp | now + 15min |
| `createdAt`          | timestamp |  |

Rules: read = owner-or-staff. write = **`false`** (server-only).

### `orders/{orderId}`

Created by the `createOrder` callable (after `reserveStock`). Client cannot create orders directly (`firestore.rules` denies `allow create`).

| Field                | Type     | Notes |
| -------------------- | -------- | ----- |
| `userId`             | string   |  |
| `businessId`         | string   |  |
| `reservationId`      | string   | from `reserveStock` |
| `items`              | array    | snapshot at order time |
| `subtotalPoisha`     | int      |  |
| `deliveryFeePoisha`  | int      |  |
| `discountPoisha`     | int      |  |
| `totalPoisha`        | int      |  |
| `pricingSnapshot`    | map      | signed snapshot |
| `pricingSignature`   | string   | HMAC |
| `paymentMethod`      | string   | `bkash` \| `nagad` \| `sslcommerz` \| `bankTransfer` \| `cod` |
| `paymentId`          | string?   | links to `payments/{paymentId}` |
| `status`             | string   | `pending_payment` → `paid` → `confirmed` → `dispatched` → `delivered` (or `cancelled`) |
| `addressId`          | string   |  |
| `riderId`            | string?  | assigned by staff |
| `couponCode`         | string?  |  |
| `note`               | string?  | customer note |
| `createdAt`, `updatedAt` | timestamp |  |

Rules: read = owner-or-staff-or-rider. create = **`false`** (server-only via `createOrder`). update = staff, OR customer self-cancellation restricted to `status == 'cancelled'` only. delete = admin.

### `payments/{paymentId}` — NEW

Server-only ledger of every payment attempt.

| Field                | Type     | Notes |
| -------------------- | -------- | ----- |
| `orderId`            | string   | links to `orders/{orderId}` |
| `userId`             | string   |  |
| `provider`           | string   | `bkash` \| `nagad` \| `sslcommerz` \| `bankTransfer` \| `cod` |
| `amountPoisha`       | int      |  |
| `currency`           | string   | `BDT` |
| `gatewayPaymentRef`  | string?  | bKash paymentID, Nagad payment_reference_id, SSLC tran_id |
| `gatewayTrxId`       | string?  | gateway's own transaction id |
| `status`             | string   | `initiated` → `pending` → `success` \| `failed` \| `cancelled` \| `refunded` |
| `bankSlipUrl`        | string?  | Storage URL (bank transfer only) |
| `verifiedAt`         | timestamp? | set by `verifyPayment` |
| `webhookPayload`     | map      | raw webhook payload (audit) |
| `refund`             | map?     | `{ amountPoisha, reason, refundedAt, refundedBy }` |
| `createdAt`, `updatedAt` | timestamp |  |

Rules: read = owner-or-staff. write = **`false`** (server-only).

### `auditLogs/{logId}` — NEW

Append-only audit trail.

| Field                | Type     | Notes |
| -------------------- | -------- | ----- |
| `actorUid`           | string   | who |
| `actorRole`          | string   |  |
| `action`             | string   | `ORDER_STATUS_CHANGE`, `PAYMENT_REFUND`, `ROLE_PROVISION`, `STOCK_ADJUST`, `RULES_DEPLOY`, ... |
| `targetCollection`   | string   |  |
| `targetId`           | string   |  |
| `before`             | map      |  |
| `after`              | map      |  |
| `ipAddress`          | string?  | from callable context |
| `userAgent`          | string?  | from callable context |
| `timestamp`          | timestamp | server-only |

Rules: create = `isAuth` (callable context). read = `isAdmin()`. update/delete = **`false`**.

### `settings/coupons/{couponId}` — NEW (coupon ledger)

| Field                | Type     | Notes |
| -------------------- | -------- | ----- |
| `code`               | string   |  |
| `discountType`       | string   | `percentage` \| `flat` |
| `discountValuePoisha` or `discountPercent` | int |  |
| `minOrderPoisha`     | int      |  |
| `maxDiscountPoisha`  | int      |  |
| `maxRedemptions`     | int      |  |
| `redemptionsCount`   | int      | server-only |
| `validFrom`, `validUntil` | timestamp |  |
| `active`             | bool     |  |

Rules: read = `true`. write = `isAdmin()` only. Redemption happens inside `calcOrder` (atomic with the order total) — `redemptionsCount` is incremented server-side.

### `prescriptions/{prescriptionId}` — NEW (healthcare security domain)

Strict healthcare sub-domain — distinct rules, distinct storage bucket.

| Field                | Type     | Notes |
| -------------------- | -------- | ----- |
| `userId`             | string   |  |
| `orderId`            | string?  | linked order, if any |
| `imageUrl`           | string   | Storage `prescriptions/...` URL |
| `extractedText`      | string?  | server-side OCR result |
| `aiAnalysis`         | map?     | server-side Gemini response |
| `status`             | string   | `pending` → `verified` \| `rejected` |
| `verifiedBy`         | string?  | pharmacist uid |
| `createdAt`          | timestamp |  |

Rules: read = owner-or-staff. create = owner. update = staff. delete = admin.

### Other collections (preserved from original)

`categories`, `stores`, `donors`, `doctors`, `helplines`, `private_chats`, `private_chats/{chatId}/messages`, `notifications`, `ai_audit_logs`, `commissions`, `staff_commissions`, `expenses`, `promos`, `hero_records`, `rateLimits`, `ai_sovereign_rules`, `notices`, `password_reset_requests`, `applications`, `monthly_stats`, `analytics`, `ai_notifications_queue`, `api_quota`, `settings`, `notes`, `user_media`, `_system/admin/{featureFlags,uiControls,branding}`, `_system/billing/{metrics,quotas,usage}`, `localization` — all preserved with tightened rules (default-deny).

---

## 3. Checkout state machine

```
                  ┌──────────────┐
                  │     idle     │
                  └──────┬───────┘
                         │ user taps "Checkout"
                         ▼
                  ┌──────────────┐
                  │   pricing    │ ← calls calcOrder(orderReq, couponCode?, ...)
                  │              │   → returns signed PricingSnapshot
                  └──────┬───────┘
                         │
                         ▼
                  ┌──────────────┐
                  │   reserved   │ ← calls reserveStock(snapshot, signature)
                  │              │   → returns reservationId (15-min TTL)
                  └──────┬───────┘
                         │
                         ▼
                  ┌──────────────┐
                  │ orderCreated │ ← calls createOrder(reservationId, paymentMethod)
                  │              │   → returns orderId, status=pending_payment
                  └──────┬───────┘
                         │
              ┌──────────┴──────────┐
              │  paymentMethod      │
              ▼                     ▼
   ┌──────────────────┐   ┌──────────────────┐
   │ redirecting      │   │ awaiting slip     │ (bank transfer)
   │ (gateway)        │   │ upload            │
   └────────┬─────────┘   └────────┬───────────┘
            │ deep link            │ recordBankPaymentRequest
            ▼                       ▼
   ┌──────────────────┐   ┌──────────────────┐
   │  verifying       │   │  verifying       │
   │  (pollPayment)   │   │  (manual review) │
   └────────┬─────────┘   └────────┬───────────┘
            │                       │
            └──────────┬────────────┘
                       ▼
                ┌──────────────┐
                │   success    │ ← order.status = paid → confirmed
                │   OR         │
                │   failed     │ ← releaseReservation(orderId, reason) on failure
                └──────────────┘
```

### Failure handling

- **`calcOrder` fails** → state returns to `idle`, no writes.
- **`reserveStock` fails** (out of stock, pricing expired, signature invalid) → state returns to `idle` with a typed exception (`InsufficientStockException`, `PricingExpiredException`, `PricingSignatureInvalidException`).
- **`createOrder` fails** → `CheckoutService` calls `releaseReservation(reservationId)` so stock isn't held for 15 minutes.
- **Payment redirect fails or user cancels** → `PaymentRedirectHandler` calls `cancel(orderId)` which calls `cancelOrder` → releases reservation → sets order `status = cancelled`.
- **`verifyPayment` fails after 2 min of polling** → order stays `pending_payment`; backend cron runs `verifyPayment` once more 5 min later; if still failing, the order is auto-cancelled by a scheduled function.

---

## 4. Payment webhook lifecycle

```
  Customer app          Cloud Functions           Gateway (bKash/Nagad/SSLC)
       │                       │                            │
       │ bkashCreatePayment    │                            │
       ├──────────────────────►│ POST /create               │
       │                       ├───────────────────────────►│
       │                       │◄───── paymentID + checkout URL
       │◄───── gatewayUrl ─────┤                            │
       │                       │                            │
       │  user pays in app     │                            │
       │───────────────────────────────────────────────────►│
       │                       │                            │
       │                       │  webhook (HTTP trigger)    │
       │                       │◄───── POST /webhook ──────┤
       │                       │                            │
       │                       │  re-query: GET /payment/status
       │                       ├───────────────────────────►│
       │                       │◄───── status=success ──────┤
       │                       │                            │
       │                       │  update payments/{id}      │
       │                       │  update orders/{id}        │
       │                       │  .status = paid            │
       │                       │  write auditLogs            │
       │                       │                            │
       │  verifyPayment poll   │                            │
       ├──────────────────────►│                            │
       │◄──── paid ────────────┤                            │
       │                       │                            │
```

Key invariants:
- The webhook and the `verifyPayment` callable both write to the same `payments/{id}` doc — Firestore transactions make the write idempotent.
- The order is only marked `paid` after BOTH the webhook AND a `verifyPayment` re-query agree.
- The client polls `verifyPayment` every 3s for up to 2 min after the redirect lands; if no success, it shows a "we're confirming your payment" screen and the backend cron completes the verification.

---

## 5. Role provisioning flow

```
                  ┌─────────────────────┐
                  │  User signs up       │
                  └──────────┬───────────┘
                             │ Auth user created
                             ▼
                  ┌─────────────────────┐
                  │  onUserCreate         │
                  │  (Firestore trigger)  │
                  │                       │
                  │  - creates users/{uid}│
                  │  - sets role=customer  │
                  │  - sets points=0      │
                  │  - writes auditLogs   │
                  └──────────┬───────────┘
                             │
                             ▼
                  ┌─────────────────────┐
                  │  Admin opens         │
                  │  provisionStaff UI   │
                  └──────────┬───────────┘
                             │
                             ▼
                  ┌─────────────────────┐
                  │  provisionStaff      │
                  │  callable            │
                  │                       │
                  │  - assertRole(admin) │
                  │  - sets custom claim │
                  │    role=staff         │
                  │  - updates users/    │
                  │    {uid}.role         │
                  │  - writes auditLogs  │
                  └──────────┬───────────┘
                             │
                             ▼
                  ┌─────────────────────┐
                  │  User refreshes     │
                  │  ID token           │
                  │  (next API call     │
                  │   gets new claim)   │
                  └─────────────────────┘
```

**Custom claims are the source of truth.** The Firestore `role` field is a defensive secondary — `firestore.rules` check claims first (`request.auth.token.role`), then fall back to the doc field for reads. The `provisionStaff` / `setUserRole` callables set BOTH the claim and the doc, atomically.

This eliminates the original bug where role was inferred from `email.startsWith('admin')`.

---

## Appendix A: Reference: Cloud Function callables

| Callable                  | Region             | Auth required | Roles                                  | Purpose |
| ------------------------- | ------------------ | ------------- | -------------------------------------- | ------- |
| `calcOrder`               | asia-southeast1    | yes           | any authed                             | compute signed pricing snapshot |
| `reserveStock`            | asia-southeast1    | yes           | customer, reseller                     | hold stock for 15 min |
| `releaseReservation`      | asia-southeast1    | yes           | owner-or-staff                         | release a reservation |
| `commitReservation`       | asia-southeast1    | yes           | server-only (called from createOrder)  | finalize stock hold |
| `createOrder`             | asia-southeast1    | yes           | customer, reseller                     | create order from reservation |
| `cancelOrder`             | asia-southeast1    | yes           | owner-or-staff                         | cancel + release reservation |
| `verifyPayment`           | asia-southeast1    | yes           | owner-or-staff                         | re-query gateway, mark paid |
| `refundPayment`           | asia-southeast1    | yes           | admin                                  | initiate refund |
| `bkashCreatePayment`      | asia-southeast1    | yes           | customer, reseller                     | init bKash checkout |
| `nagadCreatePayment`      | asia-southeast1    | yes           | customer, reseller                     | init Nagad checkout |
| `sslczCreatePayment`      | asia-southeast1    | yes           | customer, reseller                     | init SSLCommerz checkout |
| `recordBankPaymentRequest`| asia-southeast1    | yes           | customer, reseller                     | record bank slip upload |
| `searchProducts`          | asia-southeast1    | yes           | any authed                             | server-side search |
| `redeemCoupon`            | asia-southeast1    | yes           | customer                               | (deprecated — use `calcOrder` with couponCode) |
| `setUserRole`             | asia-southeast1    | yes           | admin                                  | set custom claim + doc |
| `provisionStaff`          | asia-southeast1    | yes           | admin                                  | onboard staff |
| `seedLocations`           | asia-southeast1    | yes           | admin                                  | seed hub/data/locations |
| `analyzePrescription`     | asia-southeast1    | yes           | customer, staff                        | server-side Gemini AI on prescription image |

| HTTP webhook              | Region             | Auth                     | Purpose |
| ------------------------- | ------------------ | ------------------------ | ------- |
| `bkashWebhook`            | asia-southeast1    | none (verifies signature)| bKash payment callback |
| `nagadWebhook`            | asia-southeast1    | none (verifies signature)| Nagad payment callback |
| `sslcommerzWebhook`       | asia-southeast1    | none (verifies signature)| SSLCommerz payment callback |

| Firestore trigger         | Region             | Purpose |
| ------------------------- | ------------------ | ------- |
| `onUserCreate`            | asia-southeast1    | create user profile + audit log on Auth user creation |
