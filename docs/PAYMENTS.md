# Payments

This document is the canonical reference for payment integrations in Paykari Bazar. It covers:

1. The four payment methods (bKash, Nagad, SSLCommerz, Bank transfer) + COD
2. Per-provider flow diagrams
3. Environment variables
4. Webhook URLs
5. Sandbox credentials sources
6. Testing in sandbox
7. Reconciliation procedure
8. Refund procedure
9. Idempotency design

For the trust boundary see [`SECURITY.md`](./SECURITY.md). For the checkout state machine see [`ARCHITECTURE.md` § 3](./ARCHITECTURE.md#3-checkout-state-machine).

---

## 1. Payment methods

| Method       | Provider            | Type            | Gateway URL returned to client | Webhook HTTP function |
| ------------ | ------------------- | --------------- | ------------------------------ | --------------------- |
| bKash        | bKash Tokenized API | Wallet redirect | bKash checkout URL             | `bkashWebhook`        |
| Nagad        | Nagad Checkout API  | Wallet redirect | Nagad checkout URL             | `nagadWebhook`        |
| Card / Mobile banking | SSLCommerz | Hosted checkout | SSLCommerz gateway URL         | `sslcommerzWebhook`   |
| Bank transfer| Internal (slip upload) | Manual         | (none — UI shows bank list + upload) | (none — manual review) |
| Cash on Delivery (COD) | Internal | COD | (none) | (none) |

All gateway flows follow the same pattern: `createPayment` callable → gateway URL → redirect back via `paykaribazar://payment?...` deep link → `verifyPayment` callable (server re-query).

---

## 2. bKash

### Flow

```
  Customer app          Cloud Functions                bKash API
       │                       │                          │
       │  bkashCreatePayment    │                          │
       ├──────────────────────►│ 1. grantToken            │
       │                       ├─────────────────────────►│
       │                       │◄───── id_token ──────────┤
       │                       │ 2. createPayment          │
       │                       ├─────────────────────────►│
       │                       │◄───── paymentID + bkashURL
       │◄───── gatewayUrl ─────┤                          │
       │                       │                          │
       │  user pays in bKash app                          │
       │─────────────────────────────────────────────────►│
       │                       │                          │
       │  redirect back via deep link                     │
       │  paykaribazar://payment?provider=bkash           │
       │  &paymentID=...&status=success                   │
       │                       │                          │
       │  verifyPayment        │                          │
       ├──────────────────────►│ 3. executePayment         │
       │                       ├─────────────────────────►│
       │                       │◄───── trxID + status ─────┤
       │                       │                          │
       │                       │ 4. webhook (HTTP)         │
       │                       │◄───── POST /webhook ─────┤
       │                       │                          │
       │                       │ 5. update payments/{id}   │
       │                       │    update orders/{id}     │
       │                       │    .status = paid         │
       │                       │    write auditLogs         │
       │◄───── success ────────┤                          │
```

### Env vars

```
BKASH_APP_KEY=
BKASH_APP_SECRET=
BKASH_USERNAME=
BKASH_PASSWORD=
BKASH_BASE_URL=https://tokenized.sandbox.bka.sh/v1.2.0-beta
BKASH_CALLBACK_URL=https://asia-southeast1-paykari-prod.cloudfunctions.net/bkashWebhook
```

### Sandbox credentials source

Sign up at [bKash Sandbox Portal](https://sandbox.bka.sh/login) → request a merchant account → receive `APP_KEY`, `APP_SECRET`, `USERNAME`, `PASSWORD` via email.

### Webhook URL

Register the webhook URL `https://asia-southeast1-paykari-prod.cloudfunctions.net/bkashWebhook` in the bKash merchant portal:
- Sandbox: https://sandbox.bka.sh → Settings → Webhook Configuration
- Production: contact bKash integration support (no self-serve for webhook URL in production).

### Testing in sandbox

1. Set `BKASH_BASE_URL` to the sandbox URL.
2. Use a sandbox customer wallet (sandbox portal → "Test Customer Accounts").
3. Trigger a checkout in the dev app → bKash sandbox opens.
4. Approve the payment with the sandbox PIN.
5. The `bkashWebhook` fires; verify `payments/{id}.status == 'success'` in Firestore.

---

## 3. Nagad

### Flow

NNagad uses a hybrid RSA encryption (we encrypt our payload with their public key; they sign their response with their private key).

```
  Customer app          Cloud Functions                Nagad API
       │                       │                          │
       │  nagadCreatePayment    │                          │
       ├──────────────────────►│ 1. init payment           │
       │                       │   (encrypt with Nagad     │
       │                       │    public key)            │
       │                       ├─────────────────────────►│
       │                       │◄───── payment_reference_id│
       │                       │                          │
       │                       │ 2. build checkout URL     │
       │                       │    callback URL includes │
       │                       │    payment_reference_id  │
       │◄───── gatewayUrl ─────┤                          │
       │                       │                          │
       │  user pays in Nagad app                          │
       │─────────────────────────────────────────────────►│
       │                       │                          │
       │  redirect back via deep link                     │
       │  paykaribazar://payment?provider=nagad           │
       │  &payment_reference_id=...&status=SUCCESS         │
       │                       │                          │
       │  verifyPayment        │                          │
       │                       │ 3. verify payment        │
       │                       │   (verify signature with │
       │                       │    Nagad public key)     │
       │                       ├─────────────────────────►│
       │                       │◄───── status + amount ───┤
       │                       │                          │
       │                       │ 4. webhook                │
       │                       │◄───── POST /webhook ─────┤
       │                       │                          │
       │                       │ 5. update payments/{id}   │
       │                       │    update orders/{id}     │
       │                       │    .status = paid         │
       │                       │    write auditLogs         │
       │◄───── success ────────┤                          │
```

### Env vars

```
NAGAD_MERCHANT_ID=
NAGAD_PUBLIC_KEY=
NAGAD_PRIVATE_KEY=
NAGAD_BASE_URL=https://sandbox-ssl.mynagad.com/api/dfs
NAGAD_CALLBACK_URL=https://asia-southeast1-paykari-prod.cloudfunctions.net/nagadWebhook
```

`NAGAD_PUBLIC_KEY` and `NAGAD_PRIVATE_KEY` are stored as PEM strings in Google Secret Manager.

### Sandbox credentials source

Sign up at [Nagad Merchant Portal](https://merchant.nagad.com/) → request sandbox access → receive `MERCHANT_ID`, public key, and an initial private key.

### Webhook URL

Register the webhook URL in the Nagad merchant portal under "API Configuration". Sandbox accepts self-serve; production requires support ticket.

### Testing in sandbox

1. Set `NAGAD_BASE_URL` to sandbox.
2. Use the sandbox test mobile number (provided by Nagad on sandbox activation).
3. Trigger checkout → Nagad sandbox opens → enter OTP.
4. `nagadWebhook` fires; verify status.

### Crypto notes

- We use `org.bouncycastle.**` for RSA hybrid crypto (added to `proguard-rules.pro`).
- The Nagad payload signature is verified server-side (`functions/src/payments/nagad.ts`); the client never sees the keys.

---

## 4. SSLCommerz

### Flow

SSLCommerz is the catch-all gateway for cards (Visa/Mastercard/Amex), mobile banking (Rocket, Upay), and Internet banking (City Bank, EBL, etc.).

```
  Customer app          Cloud Functions                SSLCommerz API
       │                       │                          │
       │  sslczCreatePayment   │                          │
       ├──────────────────────►│ 1. session-init          │
       │                       ├─────────────────────────►│
       │                       │◄───── sessionkey +      │
       │                       │       GatewayPageURL    │
       │◄───── gatewayUrl ─────┤                          │
       │                       │                          │
       │  user pays via card /                            │
       │  mobile banking / etc.                          │
       │─────────────────────────────────────────────────►│
       │                       │                          │
       │  redirect back via deep link                     │
       │  paykaribazar://payment?provider=sslcommerz      │
       │  &tran_id=...&status=VALID                        │
       │                       │                          │
       │  verifyPayment        │                          │
       │                       │ 2. transactionStatusValidator
       │                       ├─────────────────────────►│
       │                       │◄───── status + amount ───┤
       │                       │                          │
       │                       │ 3. webhook (IPN)          │
       │                       │◄───── POST /webhook ─────┤
       │                       │                          │
       │                       │ 4. update payments/{id}  │
       │                       │    update orders/{id}    │
       │                       │    .status = paid        │
       │                       │    write auditLogs        │
       │◄───── success ────────┤                          │
```

### Env vars

```
SSLCOMMERZ_STORE_ID=
SSLCOMMERZ_STORE_PASSWD=
SSLCOMMERZ_BASE_URL=https://sandbox.sslcommerz.com/gwprocess/v4/api.php
SSLCOMMERZ_IPN_URL=https://asia-southeast1-paykari-prod.cloudfunctions.net/sslcommerzWebhook
```

### Sandbox credentials source

Sign up at [SSLCommerz Sandbox Registration](https://developer.sslcommerz.com/) → receive `STORE_ID`, `STORE_PASSWD` via email. Sandbox accepts test cards:

- Visa: `4111111111111111`, any expiry, any CVV
- Mastercard: `5555555555554444`, any expiry, any CVV

### Webhook URL (IPN)

Register the IPN URL in the SSLCommerz merchant portal under "Store Profile → IPN". Sandbox is instant; production can take 24 hours.

### Testing in sandbox

1. Set `SSLCOMMERZ_BASE_URL` to the sandbox URL.
2. Trigger checkout → SSLCommerz sandbox opens → choose "VISA" → enter test card.
3. Use OTP `111` (or whatever the sandbox returns).
4. `sslcommerzWebhook` fires; verify status.

---

## 5. Bank transfer

### Flow

No gateway — the user uploads a slip; staff verify manually.

```
  Customer app          Cloud Functions                Storage
       │                       │                          │
       │  recordBankPayment    │                          │
       │  Request              │                          │
       │   (file bytes)        │                          │
       ├──────────────────────►│ 1. write to              │
       │                       │    paymentslips/         │
       │                       │    {uid}/{paymentId}     │
       │                       ├─────────────────────────►│
       │                       │◄───── download URL ──────┤
       │                       │                          │
       │                       │ 2. create payments/{id}  │
       │                       │    status=initiated      │
       │                       │    bankSlipUrl=URL       │
       │                       │    write auditLogs       │
       │◄───── paymentId ──────┤                          │
       │                       │                          │
       │  user sees "awaiting  │                          │
       │  verification"        │                          │
       │                       │                          │
                       Staff admin console
                       │  opens payment → views slip
                       │  marks verified (callable)
                       ▼
                       │  verifyPayment → status=success
                       │  update orders.status=paid
                       │  write auditLogs
```

### Env vars

```
BANK_ACCOUNTS_JSON=[
  {"bank":"Dutch-Bangla Bank","accountName":"Paykari Bazar Ltd","accountNumber":"123456789012","branch":"Dhanmondi"},
  {"bank":"City Bank","accountName":"Paykari Bazar Ltd","accountNumber":"123456789013","branch":"Gulshan"}
]
```

### Slip storage

- Bucket: `paymentslips/{userId}/{paymentId}`
- Rules: owner-or-staff read; owner write; 8MB max; `image/(jpeg|png|webp)` only

### Manual review queue

Staff see pending bank-transfer payments in the admin console (`payments?provider=bankTransfer&status=initiated`). Staff click "Verify" → calls `verifyPayment(paymentId)` server-side → marks `payments.status = success` → marks `orders.status = paid`.

### Reconciliation

Bank transfers must be reconciled daily against the bank statement:

1. Export the day's bank statement (CSV or PDF).
2. Match each `payments/{id}.bankSlipUrl` against the statement line items by amount + date.
3. Mark unmatched `payments.status = failed`.
4. Email customers whose payments failed (or use the in-app notification).
5. File a reconciliation report in `docs/finance/reconciliation-{YYYY-MM-DD}.md`.

---

## 6. Cash on Delivery (COD)

No gateway. `createOrder` with `paymentMethod=cod` creates the order with `status=pending_payment` (server-side). Admin flips to `confirmed` on dispatch. The rider collects cash on delivery.

COD orders are NOT marked `paid` until the rider confirms delivery via the (future) `confirmDelivery` callable.

---

## 7. Reconciliation procedure (all gateways)

### Daily

1. Cron job (Cloud Scheduler → `reconcilePayments` callable) runs at 01:00 Asia/Dhaka.
2. For each `payments/{id}` where `status == 'pending'` AND `createdAt < now - 1 hour`:
   - Call the gateway's status API again.
   - If gateway says success, mark `payments.status = success` + `orders.status = paid`.
   - If gateway says failed/cancelled, mark `payments.status = failed` + release the order's reservation.
   - If gateway says pending, leave alone; check again next day.
3. Write a summary to `auditLogs` and post to `#finance` Slack channel.

### Weekly

1. Export the `payments` collection to a sheet.
2. Cross-check totals against the gateway dashboards (bKash, Nagad, SSLCommerz).
3. Investigate any discrepancy > ৳1000.
4. File a report in `docs/finance/weekly-reconciliation-{YYYY-Www}.md`.

### Refund reconciliation

1. Weekly: list all `payments` with `refund != null` from the past week.
2. Cross-check against gateway refund dashboards.
3. Confirm each refund landed in the customer's wallet/bank within 3 business days.

---

## 8. Refund procedure

Refunds are admin-only via the `refundPayment(paymentId, {amountPoisha, reason})` callable.

### Flow

1. Admin opens the order in the admin console → clicks "Refund".
2. Admin enters the refund amount (full or partial) and a reason.
3. `refundPayment` callable:
   - `assertRole(['admin'])`
   - Loads `payments/{id}`; asserts `status == 'success'`
   - Calls the gateway's refund API (bKash/Nagad/SSLCommerz).
   - On gateway success, updates `payments.refund = {amountPoisha, reason, refundedAt, refundedBy}`
   - Updates `orders/{id}.status = 'refunded'` (full) or `partially_refunded` (partial)
   - Writes `auditLogs`
4. The customer app's order detail screen shows the refund status.
5. Customer's wallet/bank is credited by the gateway within 3 business days.

### Refund limits

- Full refund: within 30 days of payment
- Partial refund: within 30 days of payment
- Refunds beyond 30 days: contact gateway support

---

## 9. Idempotency design

The payment system is fully idempotent. Every payment has:

- A unique `paymentId` (Firestore auto-id)
- A `gatewayPaymentRef` (gateway's payment ID — bKash paymentID, Nagad payment_reference_id, SSLC tran_id)
- A unique constraint on `gatewayPaymentRef` per provider (enforced via Firestore query before write)

### Webhook + verifyPayment idempotency

Both `bkashWebhook` (or Nagad/SSLCommerz equivalent) and the `verifyPayment` callable write to `payments/{id}`. The writes are wrapped in a Firestore transaction:

```typescript
await db.runTransaction(async (tx) => {
  const ref = db.collection('payments').doc(paymentId);
  const snap = await tx.get(ref);
  if (snap.data()?.status === 'success') return;  // already paid, no-op
  tx.update(ref, {
    status: 'success',
    verifiedAt: FieldValue.serverTimestamp(),
    gatewayTrxId: ...,
    webhookPayload: webhookPayload || snap.data()?.webhookPayload,
  });
});
```

This means:
- If the webhook fires first, `verifyPayment` is a no-op.
- If `verifyPayment` fires first, the webhook is a no-op.
- If both fire at the same instant, the transaction serializes them — only one wins.

### Create payment idempotency

`bkashCreatePayment` (and equivalents) checks `payments?orderId=...&provider=...&status=initiated` first. If an initiated payment exists, returns its gateway URL instead of creating a new one. This prevents double-charging if the user taps "Pay" twice.

---

## Appendix A: Deep-link redirect format

The AndroidManifest declares intent filters for:
- `paykaribazar://payment?...` (the redirect after gateway success)
- `paykaribazar://payment-return?...` (the redirect after gateway cancel/return)

Query parameters (all four gateways):

| Provider    | Identifier param            | Status param            |
| ----------- | -------------------------- | ----------------------- |
| bKash       | `paymentID`                | `status` (success/...)  |
| Nagad       | `payment_reference_id`     | `status` (SUCCESS/...)  |
| SSLCommerz  | `tran_id`                  | `status` + `payment_status` + `tran_status` (VALID/...) |
| Bank        | (n/a — no redirect)        | (n/a)                   |

`PaymentRedirectHandler` parses all of these and routes to `verifyPayment`.
