# Paykari Bazar — Cloud Functions Backend

This is the **trust boundary** for the Paykari Bazar Flutter/Firebase B2B
marketplace. Money, inventory, role escalation and order creation all live
here. The Flutter client never computes totals, never decrements stock, never
assigns itself a role, and never marks a payment as paid — all of that happens
behind these callables.

## Trust model at a glance

| Concern                  | Old (insecure)            | New (this backend)                                            |
| ------------------------ | ------------------------- | ------------------------------------------------------------- |
| Order totals             | client-side float math    | `calcOrder` → HMAC-signed `PricingSnapshot`                   |
| Stock updates            | `stock = newStock`        | Firestore transactions with `reservedStock` + `soldStock`     |
| Role assignment          | inferred from email       | `onUserCreate` sets `customer`; admin uses `setUserRole`      |
| Payments                 | `return true`             | bKash / Nagad / SSLCommerz / Bank, server-verified webhooks    |
| Marking an order paid    | client write              | webhooks + `verifyPayment` callable, idempotent                |
| Admin seeding on launch  | client `DatabaseSeeder`   | `runSeed` callable, admin-only                                |

## Layout

```
functions/
├── package.json
├── tsconfig.json
├── .env.example              # ← every secret the backend needs
├── README.md
└── src/
    ├── index.ts              # exports every callable + HTTPS webhook
    ├── admin.ts              # admin app, db, auth, assertAuth / assertRole
    ├── shared/
    │   └── security.ts       # HMAC sign/verify, poisha money math, HttpsErrors
    ├── audit/auditLog.ts    # recordAudit → auditLogs/{id}
    ├── users/onUserCreate.ts # Firestore trigger: assigns default customer claim
    ├── admin/
    │   ├── provisionStaff.ts
    │   ├── provisionRole.ts
    │   └── seedLocations.ts  # replaces client-side DatabaseSeeder
    ├── pricing/calcOrder.ts  # THE pricing engine — returns signed snapshot
    ├── inventory/
    │   ├── reserveStock.ts
    │   ├── releaseReservation.ts
    │   └── commitReservation.ts  # internal helper used by webhooks
    ├── orders/
    │   ├── createOrder.ts
    │   └── cancelOrder.ts
    ├── payments/
    │   ├── _http.ts              # axios wrapper, TokenCache, sanitiser
    │   ├── bkash.ts
    │   ├── nagad.ts
    │   ├── sslcommerz.ts
    │   ├── bank.ts
    │   ├── verifyPayment.ts      # client polls after redirect
    │   ├── refund.ts             # admin-only, full + partial
    │   └── webhooks/
    │       ├── _shared.ts        # verifyHmac + idempotent markPaymentPaid
    │       ├── bkashWebhook.ts
    │       ├── nagadWebhook.ts
    │       └── sslcommerzWebhook.ts
    ├── coupons/redeem.ts     # transactional currentUses++/usedBy push
    ├── search/productSearch.ts
    └── health/prescriptionProcess.ts  # Gemini vision, doctor/admin only
```

## Checkout flow (Flutter side)

```
1. calcOrder({items, addressId, couponCode?})
   → {snapshot, signature, expiresAt: +10min}
2. reserveStock({snapshot, signature})
   → {reservationId, expiresAt: +15min}
3. createOrder({snapshot, signature, reservationId, addressId, paymentMethod})
   → {orderId}      // status: pending_payment, paymentStatus: unpaid
4. {bkash|nagad|sslcz}CreatePayment({orderId})
   → {gatewayUrl, paymentRefId}    // navigate user to gatewayUrl
5. (return) verifyPayment({provider, paymentRefId, orderId})  // poll ~3s
   → webhook fires asynchronously; markPaymentPaid → commitReservation
   → order.status = 'confirmed', paymentStatus = 'paid'
```

For bank transfers the customer uploads a slip and an admin calls
`verifyBankPayment({paymentId, decision})` instead of steps 4–5.

## Deploy

```bash
# 1. install deps
cd functions && npm install

# 2. set secrets (do once per project)
firebase functions:secrets:set BKASH_APP_KEY
firebase functions:secrets:set BKASH_APP_SECRET
firebase functions:secrets:set BKASH_USERNAME
firebase functions:secrets:set BKASH_PASSWORD
firebase functions:secrets:set BKASH_CALLBACK_URL
firebase functions:secrets:set NAGAD_MERCHANT_ID
firebase functions:secrets:set NAGAD_MERCHANT_PRIVATE_KEY
firebase functions:secrets:set NAGAD_MERCHANT_PUBLIC_KEY
firebase functions:secrets:set NAGAD_CALLBACK_URL
firebase functions:secrets:set SSLCOMMERZ_STORE_ID
firebase functions:secrets:set SSLCOMMERZ_STORE_PASSWORD
firebase functions:secrets:set GEMINI_API_KEY
firebase functions:secrets:set WEBHOOK_HMAC_SECRET
# (etc — see .env.example)

# 3. build + deploy
npm run build
firebase deploy --only functions
```

## Environment

Node 20, TypeScript 5, Firebase Functions SDK 4 (2nd gen). Region
`asia-southeast1` for all functions (closest GCP region to Bangladesh).

Secrets live in Google Secret Manager and are bound at deploy time. The
client NEVER sees them. `FIREBASE_ADMIN_SERVICE_ACCOUNT_JSON` is optional —
when running inside Cloud Functions the runtime service account is used via
`applicationDefault()`.

## Firestore / Storage rules

The Firestore rules MUST be locked down so that:

- `users/{uid}.role` is writable only by Cloud Functions (admin SDK).
- `orders/{orderId}.paymentStatus` and `.status` are writable only by Cloud
  Functions.
- `products/{productId}.stock`, `.reservedStock`, `.soldStock` are writable
  only by Cloud Functions.
- `payments/{paymentId}` is readable by the owning customer + admin/staff,
  writable only by Cloud Functions.
- `inventoryReservations/{id}` is writable only by Cloud Functions.
- `auditLogs/{id}` is read-only for admins, write-only for everyone else
  (they can append through this backend only).
- Storage `paymentslips/{uid}/{paymentId}.jpg` is writable by the owner
  only, readable by admin/staff only.

See `firestore.rules` and `storage.rules` patches (authored separately).

## Local emulation

```bash
npm run serve
```

Starts the Firebase emulator for functions. Make sure the secrets above are
exposed in your shell (or via `firebase functions:secrets:access`) before
invoking payment routes in the emulator.
