# 🌟 পাইকারী বাজার (Paykari Bazar) — Master Blueprint v2.0
## সম্পূর্ণ ফিচার, বিজনেস ওয়ার্কফ্লো, টেকনিক্যাল আর্কিটেকচার এবং Production Readiness

**ডকুমেন্ট সংস্করণ:** 2.0  
**আপডেট:** সেপ্টেম্বর ২০২৬  
**ভিত্তি:** বর্তমান `main` branch-এর repository structure + বিদ্যমান Master Blueprint  
**ডকুমেন্ট স্ট্যাটাস:** **Living Master Blueprint — Production hardening required before declaring production-ready**  
**প্ল্যাটফর্ম:** Flutter Customer App + Flutter Admin App + Firebase ecosystem + CI/CD + Shorebird OTA

> **গুরুত্বপূর্ণ:** এই Blueprint-এ “Implemented”, “Partial/Needs Verification”, “Planned/Required” আলাদা করা হয়েছে। কোনো feature-এর নাম document-এ থাকা মানেই সেটি production-safe বা end-to-end complete নয়।

---

# 📌 সূচিপত্র

1. প্রকল্পের Vision ও Business Scope
2. Current System Reality — কী আছে, কী partial, কী gap
3. Architecture & Technology Stack
4. Dual-App Architecture
5. App Startup & Lifecycle
6. User, Role & Access Model
7. Product Catalog & Commerce Engine
8. Cart & Checkout Workflow
9. Pricing, Coupon & Loyalty
10. Payment Architecture
11. Order Lifecycle & Fulfillment
12. Inventory & Warehouse
13. Location, Delivery & Fleet
14. Customer Experience
15. Reseller / B2B Business
16. Emergency Healthcare Hub
17. Chat, Support & Notifications
18. AI & Automation Platform
19. Admin Operations Center
20. Analytics, Reporting & Business KPIs
21. Data Architecture & Firestore Collections
22. Security & Privacy
23. Backup, Recovery & Resilience
24. Search & Discovery
25. Localization & Branding
26. Web, Mobile, Desktop & OTA
27. CI/CD & Release Process
28. Testing Strategy
29. Production Gaps — P0 / P1 / P2
30. Business Work Process — End-to-End
31. Recommended Production Roadmap
32. Source-of-Truth Rules for Future Development
33. Change Log

---

# ১. প্রকল্পের Vision ও Business Scope

**পাইকারী বাজার (Paykari Bazar)** হলো একটি Bangladesh-focused digital commerce ecosystem, যার মূল ব্যবসায়িক কেন্দ্র হলো:

1. **B2C commerce** — সাধারণ ক্রেতার জন্য পণ্য কেনাকাটা।
2. **B2B / wholesale commerce** — দোকানদার, reseller এবং ব্যবসায়িক ক্রেতাদের bulk purchasing।
3. **Hyperlocal logistics** — location-based delivery charge, delivery zones, rider operations।
4. **Customer retention** — coupon, loyalty, rewards, referral, wallet-oriented features।
5. **Operational back-office** — inventory, orders, staff, fleet, analytics, marketing, configuration।
6. **Emergency service layer** — medicine/prescription, blood donors, doctors, helplines।
7. **AI assistance** — product enrichment, AI assistant, audits, forecasting, review/prescription support।
8. **Multi-platform delivery** — Android/iOS/Web/Desktop-ready application structure।

### Business principle

```text
Catalog
  ↓
Discovery
  ↓
Cart
  ↓
Verified Price
  ↓
Stock Check
  ↓
Checkout
  ↓
Payment / COD
  ↓
Order Confirmation
  ↓
Warehouse / Picking
  ↓
Rider Dispatch
  ↓
Delivery
  ↓
Reorder / Loyalty / Retention
```

---

# ২. Current System Reality — Repository Review

## ২.১ বর্তমান codebase-এ দৃশ্যমান বড় feature domains

### Customer-side domains

- Authentication
- Home
- Product catalog
- Category navigation
- Product details
- Search
- Cart
- Wishlist
- Orders
- Order tracking
- Emergency / medicine order
- Chat
- Notifications
- Profile
- Edit profile
- Wallet
- Rewards
- Bonus / cashback
- Backup
- Cloud storage
- Customer simulator
- Reseller application
- Staff/rider application
- Qibla / compass
- Localization
- Theme
- OTA/update flow

### Commerce services

- Product service
- Order service
- Cart service
- Coupon service
- Loyalty service
- Group buying service
- POS/cart service
- Pagination
- Delivery/location pricing
- Business configuration

### Admin operations

- Dashboard
- Orders
- Inventory
- Inventory forecasting
- Catalog/products
- Categories
- Shops
- Delivery zones
- Logistics
- Fleet
- Staff management
- Staff security
- HR/teams
- Accounts/finance
- Commissions
- Marketing
- Feedback
- Notifications
- Chat management
- Emergency management
- Analytics
- AI master
- AI audit
- AI notifications
- Database management
- Localization
- System health
- Settings
- Device requests
- Notices
- Operations

### Platform / engineering

- Firebase Auth
- Firestore
- Firebase Storage
- Firebase Messaging
- Firebase Analytics dependency
- Firebase Crashlytics dependency
- Firebase App Check
- Sentry
- WorkManager/background tasks
- Shorebird OTA
- GitHub Actions
- Security scans
- SBOM generation
- Coverage reports
- Integration tests

## ২.২ বর্তমান status legend

| Status | অর্থ |
|---|---|
| ✅ Implemented | source code-এ বাস্তব implementation পাওয়া গেছে |
| ⚠️ Partial / Needs Verification | feature বা service আছে, কিন্তু end-to-end/production readiness যাচাই প্রয়োজন |
| 🔴 Production Blocker | বাস্তব ব্যবসা চালানোর আগে ঠিক করা দরকার |
| 📋 Planned / Required | architecture বা business roadmap হিসেবে দরকার |

---

# ৩. Architecture & Technology Stack

## ৩.১ Application

- Flutter / Dart
- Riverpod state management
- GetIt dependency injection
- GoRouter navigation
- Feature-oriented `lib/src/` structure
- Shared service layer

## ৩.২ Firebase

- Firebase Auth
- Cloud Firestore
- Firebase Storage
- Firebase Messaging
- Firebase App Check
- Firebase Analytics dependency
- Firebase Crashlytics dependency
- Remote config/configuration patterns

## ৩.৩ Supporting services

- Sentry
- Shorebird
- WorkManager
- Secure Storage
- Hive
- SharedPreferences
- Image compression
- PDF/invoice tooling
- Google Maps
- Geolocation
- CSV import

## ৩.৪ AI

বর্তমান source code-এ AI provider architecture আছে:

- Gemini provider
- DeepSeek provider
- Kimi/NVIDIA provider structure
- Fallback provider
- AI provider manager
- AI cache
- API quota service
- AI audit / automation service

### Production note

AI keys client application-এ exposed হওয়া উচিত নয়। Production architecture হবে:

```text
Flutter
  ↓
Backend AI Gateway
  ↓
Secret Manager
  ↓
Gemini / DeepSeek / Kimi
```

---

# ৪. Dual-App Architecture

একটি root codebase থেকে:

| App | Entry point | Audience |
|---|---|---|
| Customer | `lib/main_customer.dart` | Customer / retailer / reseller |
| Admin | `lib/main_admin.dart` | Owner / admin / operations / staff |

### Customer application

প্রধান কাজ:

- Browse
- Search
- Cart
- Checkout
- Orders
- Tracking
- Wishlist
- Wallet/rewards
- Support/chat
- Emergency services
- Profile

### Admin application

প্রধান কাজ:

- Orders
- Inventory
- Catalog
- Logistics
- Staff
- Resellers
- Marketing
- Finance
- AI
- System configuration
- Analytics

---

# ৫. App Startup & Lifecycle

বর্তমান startup architecture-এ service initialization রয়েছে:

```text
Phase 1
Core / cache / connectivity / security

Phase 2
Firebase / Auth / App Check / Messaging

Phase 3
Domain services

Phase 4
Data seeding / synchronization
```

### Production correction

**Database seeding production app startup থেকে আলাদা করা উচিত।**

Production flow:

```text
Deploy / Migration Job
        ↓
Database initialization

Customer/Admin App
        ↓
Initialize services
        ↓
Authenticate
        ↓
Load config
        ↓
Render UI
```

App opening-এর সময়ে destructive বা broad database mutation করা যাবে না।

---

# ৬. User, Role & Access Model

## Defined/used roles

- `customer`
- `reseller`
- `staff`
- `admin`
- `rider`
- `logistic`
- `marketing`
- `accountsFinance`
- অন্যান্য operational role

## Authentication

Source code-এ বাস্তবভাবে পাওয়া:

- Email/password
- Google sign-in
- Phone-number-as-email-style internal account pattern

### Needs verification / not currently proven by source

- Phone OTP end-to-end
- Facebook sign-in

Dependency/configuration থাকলেও feature complete বলে document-এ লিখতে হলে implementation + test নিশ্চিত করতে হবে।

## Authorization principle

```text
UI role check = UX

Firestore/backend authorization = Security
```

Admin/staff creation ও role assignment production-এ backend/admin-controlled হওয়া উচিত।

---

# ৭. Product Catalog & Commerce Engine

## Product capabilities

Product model-এ দেখা যায়:

- Product ID
- SKU
- Name / Bangla name
- Description / Bangla description
- Price
- Old price
- Purchase price
- Wholesale price
- Minimum wholesale quantity
- Tiered prices
- Stock
- Unit
- Images / image URLs
- Category
- Sub-category
- Brand
- Tags
- Flash sale
- Combo
- Featured
- New arrival
- Hot selling
- Rating
- Sales count
- AI optimization flags
- Variants

## Category system

- Category
- Sub-category
- Category navigation
- Admin category management

## Catalog import

- CSV-based import/seeding
- Bulk product management

### Production requirement

Catalog should also have:

- SKU uniqueness
- barcode support
- product status
- approval status
- supplier/source
- tax/VAT policy where applicable
- price history
- audit trail
- stock reservation
- image moderation
- product publishing workflow

---

# ৮. Cart & Checkout Workflow

## Current cart capabilities

- Add item
- Increase/decrease quantity
- Remove item
- Persist cart to Firestore
- Restore cart
- Selected address
- Delivery fee calculation
- Coupon discount
- Minimum order value
- Weight-related delivery calculation

## Checkout desired production workflow

```text
Customer
 ↓
Cart validation
 ↓
Fetch current product price
 ↓
Check stock
 ↓
Apply wholesale tier
 ↓
Validate coupon
 ↓
Calculate delivery
 ↓
Calculate final total
 ↓
Reserve stock
 ↓
Create payment intent
 ↓
Payment / COD
 ↓
Confirm order
```

### 🔴 Critical production rule

Client must **not** be trusted as the source of:

- final price
- discount
- delivery fee
- stock
- payment success
- coupon usage

Server/backend must recalculate these.

---

# ৯. Pricing, Coupon & Loyalty

## Wholesale / tier pricing

Support exists for:

- wholesale price
- minimum wholesale quantity
- quantity-based pricing
- tiered prices

## Coupon

Current service supports:

- fixed discount
- percentage discount
- minimum order requirement
- max discount
- expiry
- max uses
- user-specific usage

### 🔴 Production requirement

Coupon usage must be atomic.

```text
Validate
  ↓
Reserve/consume
  ↓
Create order
```

একই coupon একই সময়ে multiple users/retries দ্বারা double-consume হওয়া ঠেকাতে transaction/idempotency দরকার।

## Loyalty

Current implementation contains:

- signup bonus
- purchase points
- referral bonus
- daily login points
- points ledger
- top buyer / hero statistics

### Production requirement

Points ledger should be immutable and server-controlled.

---

# ১০. Payment Architecture

## Currently present conceptually

- COD
- bKash
- Nagad
- wallet-related flows

## Current implementation reality

`PaymentServiceImpl`-এর bKash/Nagad এবং payment verification methods placeholder/simulated implementation হিসেবে রয়েছে।

### 🔴 Production blocker

Real gateway integration ছাড়া payment feature complete বলা যাবে না।

## Required payment flow

```text
Order Draft
 ↓
Payment Intent
 ↓
Gateway
 ↓
Callback/Webhook
 ↓
Signature / status verification
 ↓
Idempotency check
 ↓
Payment record
 ↓
Order = Paid
```

## Required payment states

- unpaid
- pending
- paid
- failed
- cancelled
- refunded
- partially_refunded

## Required records

- paymentId
- orderId
- gateway
- transactionId
- amount
- currency
- initiatedAt
- verifiedAt
- status
- raw reference
- reconciliation status

---

# ১১. Order Lifecycle & Fulfillment

## Current order states

Repository/doc conventions include:

- Pending
- Confirmed
- Processing
- Shipped
- Delivered
- Cancelled

## Recommended production state machine

```text
Draft
 ↓
Pending Payment
 ↓
Paid / COD Confirmed
 ↓
Confirmed
 ↓
Picking
 ↓
Packed
 ↓
Ready for Dispatch
 ↓
Assigned to Rider
 ↓
Out for Delivery
 ↓
Delivered
```

Alternative paths:

```text
Cancelled
Payment Failed
Return Requested
Returned
Refund Pending
Refunded
```

### Order source of truth

Order must snapshot:

- items
- unit price
- quantity
- subtotal
- discount
- delivery fee
- grand total
- payment status
- customer
- address
- pricing version
- coupon
- stock reservation
- rider
- timestamps

---

# ১২. Inventory & Warehouse

## Current capabilities

- Product stock field
- Admin inventory tab
- Inventory forecasting widget
- Product stock update service
- SKU-oriented model support

## Required production inventory architecture

```text
availableStock
reservedStock
damagedStock
soldStock
```

Order process:

```text
Checkout
 ↓
Reserve
 ↓
Payment/confirmation
 ↓
Deduct / finalize
```

Cancel/failure:

```text
Release reservation
```

### 📋 Future/required

- Warehouses
- Bin/location
- stock transfer
- purchase receiving
- supplier inventory
- stock adjustment reason
- audit log
- low-stock alert
- batch/expiry for medicine
- barcode scanning

---

# ১৩. Location, Delivery & Fleet

## Location hierarchy

```text
District
  ↓
Upazila
  ↓
Area
```

## Delivery

Current code supports concepts around:

- location-based fee
- base charge
- max charge
- extra weight charge
- delivery configuration
- location data provider
- logistics admin screens

## Fleet

Admin-side structure includes:

- Fleet
- Riders
- Logistics
- Rider tracker
- Rider applications
- Staff applications

## Recommended delivery workflow

```text
Order Ready
 ↓
Dispatch Queue
 ↓
Rider Assignment
 ↓
Pickup
 ↓
Out for Delivery
 ↓
Customer Contact
 ↓
Delivered / Failed
```

## Live tracking

The repository contains rider tracking structures, but real production SLA (update interval, battery policy, privacy and backend authorization) must be verified before documenting live tracking as guaranteed.

---

# ১৪. Customer Experience

## Home

- Home screen
- promotional/banners
- product discovery
- dynamic configurations
- recommendation areas

## Product discovery

- Categories
- Product list
- Product details
- Related products
- Wishlist
- Search

## Cart

- Floating cart
- Persistent cart
- Address-aware delivery fee

## Order

- Orders list
- Order details
- Order tracking

## Notifications

- notification screen
- FCM infrastructure
- admin custom notification support

## Profile

- Profile
- Edit profile
- How-to-use
- Info
- Cloud storage
- Backup
- Wallet
- Customer simulator

## Rewards

- Rewards screen
- Bonus/cashback screen
- Loyalty points
- Referral-related logic

---

# ১৫. Reseller / B2B Business

## Current reseller architecture

- Reseller application
- Reseller role
- Reseller services
- Wholesale pricing concepts
- reseller-oriented workflows

## Recommended B2B model

```text
Business
 ├── Owner
 ├── Buyer
 ├── Accountant
 └── Delivery Contact
```

Business-level capabilities:

- business-specific pricing
- MOQ
- bulk order
- repeat order
- invoice
- payment terms
- credit limit
- business wallet
- monthly statements

### High-value feature: Quick Reorder

```text
Previous Order
 ↓
Buy Again
```

এটি B2B retention-এর জন্য priority feature হওয়া উচিত।

---

# ১৬. Emergency Healthcare Hub

## Current visible domains

- Emergency medicine order
- Prescription upload
- Blood donors
- Doctors
- Helplines
- Emergency details
- Order tracking/support

## Blood donor workflow

```text
Register donor
 ↓
Blood group
 ↓
Location
 ↓
Availability / cooldown
 ↓
Search
 ↓
Call / contact
```

## Medicine/prescription workflow

```text
Customer
 ↓
Upload prescription
 ↓
Medicine request
 ↓
Admin/pharmacy review
 ↓
Stock check
 ↓
Quote/order
 ↓
Delivery
```

### 🔴 Production privacy requirement

Prescription/medical data must have:

- strict access control
- audit logs
- secure storage
- retention/deletion policy
- server-side authorization
- restricted AI processing
- human verification where medically necessary

AI should not be the final medical decision-maker.

---

# ১৭. Chat, Support & Notifications

Current feature domains include:

- General chat
- Private chat
- Chat history
- Admin chat management
- Notifications
- Custom notifications
- AI notifications

Recommended support workflow:

```text
Customer creates issue
 ↓
Ticket / chat
 ↓
Staff assignment
 ↓
Resolution
 ↓
Audit
```

---

# ১৮. AI & Automation Platform

## Current AI structure

- AIService
- AI provider manager
- Gemini provider
- DeepSeek provider
- Kimi/NVIDIA provider structure
- Fallback provider
- AI cache
- quota service
- forecasting
- AI automation
- AI audit logs
- AI notifications

## Current AI use cases

- Product enrichment
- Bengali description generation
- SEO tags
- Pricing suggestions
- Order anomaly/fraud signals
- Review summarization
- AI assistant
- Prescription image assistance
- System diagnostics
- Inventory optimization/forecasting

## AI automation

The repository includes:

- background audit
- pending AI task processing
- product optimization
- AI audit logging

### Production boundary

AI may recommend/classify/summarize.

AI must not be final authority for:

- money movement
- payment verification
- stock accounting
- legal/accounting records
- irreversible account permissions
- medical diagnosis

---

# ১৯. Admin Operations Center

বর্তমান admin codebase-এর visible management surface অত্যন্ত বিস্তৃত।

## Commerce & catalog

- Commerce hub
- Catalog
- Categories
- Product form
- Shops
- Inventory
- Orders

## Operations

- Operations
- Logistics
- Delivery zones
- Fleet
- Orders
- Device requests
- System health

## People

- Staff management
- Staff security
- HR teams
- Teams
- Reseller applications

## Finance

- Accounts
- Commissions
- Staff commissions
- Expenses

## Marketing

- Marketing hub
- Marketing
- Notices
- Custom notifications

## Customer support

- Feedback
- Interactions
- Chat management
- Emergency

## AI / analytics

- AI master
- AI audit
- AI notifications
- Analytics
- Forecasting

## Platform

- Database
- Localization
- Settings
- System health
- Dynamic config

---

# ২০. Analytics, Reporting & Business KPIs

Analytics-related source code and admin tabs exist, but business-grade measurement should be standardized.

## Must-track KPIs

### Sales

- Orders/day
- GMV
- Revenue
- Gross margin
- Average order value
- Cancellation rate
- Return rate

### Customer

- New customers
- Active customers
- Repeat purchase rate
- Retention
- Reorder interval

### Operations

- Fulfillment time
- Delivery time
- Failed delivery rate
- Stock-out rate
- Fill rate

### B2B

- Active retailers
- Average business spend
- Bulk order count
- Wholesale margin
- Reorder frequency

### Marketing

- Coupon conversion
- Referral conversion
- Campaign ROI
- CAC
- Organic vs paid acquisition

---

# ২১. Data Architecture & Firestore Collections

## Current major paths

```text
users/{uid}

orders/{orderId}

hub/data/products/{productId}

hub/data/categories/{categoryId}

hub/data/stores/{storeId}

hub/data/locations/{locationId}

hub/emergency/donors/{donorId}

hub/emergency/doctors/{doctorId}

hub/emergency/helplines/{helplineId}

private_chats/{chatId}

notifications/{notificationId}

commissions/{commissionId}

staff_commissions/{commissionId}

expenses/{expenseId}

promos/{promoId}

hero_records/{heroId}

rateLimits/{userId}

ai_audit_logs/{logId}

ai_notifications_queue/{notifId}

api_quota/{provider}

settings/{docId}
```

## Recommended additional financial/operational collections

```text
payments/{paymentId}

inventory/{skuId}

inventoryReservations/{reservationId}

returns/{returnId}

refunds/{refundId}

auditLogs/{logId}

businesses/{businessId}

businessMembers/{membershipId}

priceRules/{ruleId}
```

---

# ২২. Security & Privacy

## Present security infrastructure

- Firebase App Check
- AES encryption service
- Secure storage
- Biometric support
- API security service
- role constraints
- Firestore rules
- Storage rules
- Sentry
- Crashlytics dependency
- secret service

## 🔴 Required hardening

### ১. Client secrets

`.env` should not contain production backend secrets in a Flutter asset.

### ২. Hardcoded fallback credentials

Security fallback credentials must be removed.

### ৩. User data rules

Authenticated users should not automatically read other users' private documents.

### ৪. Wallet/points

Customers should not be allowed to write their own ledger entries.

### ৫. Order money fields

Client must not be the final authority for total/discount/delivery/payment success.

### ৬. Role assignment

Role creation and escalation must be backend/admin-controlled.

### ৭. Medical data

Prescription and health information requires extra restrictive access control.

---

# ২৩. Backup, Recovery & Resilience

Current codebase contains:

- Backup service
- Backup screen
- Storage service
- Cloud storage screen
- Firebase Storage
- background task support

## Required recovery strategy

```text
Primary Firestore
        ↓
Automated backup
        ↓
Versioned retention
        ↓
Restore test
```

Recovery must be tested, not only implemented.

Required documentation:

- RPO
- RTO
- restore procedure
- incident process
- who can restore
- backup retention

---

# ২৪. Search & Discovery

## Current

- Search screen
- Search utilities
- product query/filtering
- client-side matching in product service
- paginated product loading

## Scale requirement

For large catalogs:

```text
Firestore catalog
        +
Dedicated search index
```

Search should support:

- Bangla
- English
- SKU
- brand
- category
- synonym
- typo tolerance
- wholesale intent
- voice/image-assisted search

---

# ২৫. Localization & Branding

Current architecture contains:

- English
- Bangla
- HindSiliguri font
- localization strings
- dynamic UI controls/config
- localization admin tab

Production requirement:

- centralized translation keys
- no critical hard-coded strings
- Bangla QA
- number/currency formatting
- date/time formatting
- RTL readiness if ever required
- transactional notification localization

---

# ২৬. Web, Mobile, Desktop & OTA

## Mobile

- Android
- iOS project structure

## Web

- Customer web hosting
- Admin web hosting
- Firebase Hosting configuration
- FCM service worker

## Desktop

- Linux
- macOS project structure
- Windows support should be verified separately

## OTA

Shorebird integration exists for rapid code patches.

### Important

OTA is not a replacement for:

- schema migration
- native dependency updates
- permission changes
- major Firebase configuration
- release signing
- store metadata

---

# ২৭. CI/CD & Release Process

Current repository contains:

- auto-build workflow
- release workflow
- security workflow
- dependency update workflow
- docs workflow
- deployment scripts
- test scripts
- Shorebird release
- Firebase deployment

## Recommended release pipeline

```text
Pull Request
   ↓
Format
   ↓
Analyze
   ↓
Unit tests
   ↓
Widget tests
   ↓
Integration/E2E
   ↓
Firestore emulator rules tests
   ↓
Storage rules tests
   ↓
Secret scan
   ↓
Dependency scan
   ↓
Build
   ↓
Staging
   ↓
Smoke test
   ↓
Manual approval
   ↓
Production
```

### CI hardening

Security checks should be **blocking** where appropriate.

Production signing must fail if release keystore is missing; debug signing must never be an automatic production fallback.

---

# ২৮. Testing Strategy

## Existing test families

Repository contains:

- unit tests
- widget tests
- provider tests
- service tests
- core service tests
- integration tests
- performance tests
- fixtures/helpers
- checkout flow tests

## Required production test matrix

### Commerce

- product price change
- stock race
- coupon race
- duplicate checkout
- order retry
- payment retry
- cancellation
- refund

### Security

- unauthorized user read
- role escalation
- reseller access
- staff access
- admin access
- storage path isolation
- medical data isolation

### Operations

- rider assignment
- delivery failure
- return
- refund
- stock release

### Reliability

- offline
- slow network
- timeout
- duplicate callback
- app killed during checkout

---

# ২৯. Production Gaps — Priority

## 🔴 P0 — Must fix before real-money production

1. Real bKash/Nagad payment integration
2. Server-side payment verification
3. Server-side price calculation
4. Server-side discount/coupon enforcement
5. Atomic stock reservation
6. Strict Firestore/Storage authorization
7. Remove client-side production secrets
8. Remove hardcoded secret fallbacks
9. Backend-controlled role assignment
10. Fix auth/signup consistency issues
11. Prevent client-created financial ledger mutations
12. Production release signing must never fall back to debug signing

## 🟠 P1 — Strongly recommended before scale

1. Dedicated backend/API gateway
2. Audit log standardization
3. Reconciliation system
4. Return/refund engine
5. Warehouse model
6. Business accounts
7. Search index
8. KPI event taxonomy
9. Staging environment
10. Automated restore tests
11. Strict CI quality gates

## 🟡 P2 — Growth/optimization

1. Recommendation engine
2. Advanced search
3. Personalized promotions
4. Advanced B2B credit
5. Supplier portal
6. Multi-warehouse optimization
7. More AI automation
8. Advanced demand forecasting

---

# ৩০. Business Work Process — End-to-End

## A. Customer purchase

```text
Register/Login
 ↓
Select location
 ↓
Browse/Search
 ↓
Open product
 ↓
Check wholesale/tier price
 ↓
Add to cart
 ↓
Select address
 ↓
System recalculates delivery fee
 ↓
Apply coupon
 ↓
Server recalculates final total
 ↓
Reserve stock
 ↓
Choose payment
 ↓
Payment verified / COD confirmed
 ↓
Order confirmed
 ↓
Warehouse picks
 ↓
Packed
 ↓
Rider assigned
 ↓
Out for delivery
 ↓
Delivered
 ↓
Loyalty/reward settlement
 ↓
Reorder / retention
```

## B. Admin order process

```text
New Order
 ↓
Payment Check
 ↓
Fraud/Anomaly Signal
 ↓
Inventory Check
 ↓
Picking
 ↓
Packing
 ↓
Dispatch
 ↓
Rider Assignment
 ↓
Delivery
 ↓
Settlement
 ↓
Report
```

## C. Reseller process

```text
Customer
 ↓
Reseller application
 ↓
Admin review
 ↓
Reseller approval
 ↓
Wholesale pricing
 ↓
Bulk order
 ↓
Commission / margin
 ↓
Delivery
 ↓
Repeat order
```

## D. Coupon process

```text
Coupon Created
 ↓
Eligibility Rule
 ↓
Customer Enters Code
 ↓
Server Validation
 ↓
Atomic Reservation/Consumption
 ↓
Order Confirmation
 ↓
Usage Record
```

## E. Payment process

```text
Order
 ↓
Payment Intent
 ↓
Gateway
 ↓
Callback/Webhook
 ↓
Backend Verification
 ↓
Idempotency
 ↓
Payment Record
 ↓
Order Paid
```

## F. Inventory process

```text
Catalog
 ↓
Stock Received
 ↓
Available
 ↓
Reserved
 ↓
Picked
 ↓
Sold
```

Cancellation:

```text
Reserved
 ↓
Cancelled
 ↓
Stock Released
```

## G. Emergency medicine process

```text
Prescription / Medicine Request
 ↓
Secure upload
 ↓
Pharmacist review
 ↓
Medicine availability
 ↓
Price/availability confirmation
 ↓
Order
 ↓
Priority fulfillment
 ↓
Delivery
```

---

# ৩১. Recommended Production Roadmap

## Phase 1 — Trust & Safety

- Move secrets to backend
- Harden Firestore rules
- Harden Storage rules
- Fix role provisioning
- Fix auth edge cases
- Remove production debug fallbacks

## Phase 2 — Money & Inventory

- Implement backend pricing
- Implement inventory reservation
- Implement real payment gateway
- Implement payment verification
- Implement coupon transactions
- Implement refund/reconciliation

## Phase 3 — Operations

- Warehouse
- Picking
- Packing
- Dispatch
- Rider assignment
- Failed delivery
- Return
- Refund

## Phase 4 — B2B Growth

- Business accounts
- MOQ
- tiered business pricing
- quick reorder
- invoice
- payment terms
- credit limit
- retailer management

## Phase 5 — Growth Intelligence

- Search engine
- personalization
- recommendations
- advanced analytics
- lifecycle marketing
- AI optimization

---

# ৩২. Source-of-Truth Rules for Future Development

এই Blueprint future development-এর সময় একটি rulebook হিসেবে ব্যবহার হবে।

## Rule 1

**Document claim ≠ implementation proof**

কোনো feature source code, test বা verified deployment ছাড়া “100% complete” বলা যাবে না।

## Rule 2

**Money truth must be server-side**

Price, discount, stock, payment, wallet, refund — client-controlled নয়।

## Rule 3

**Security truth must be backend/rules-side**

UI hiding কখনো security নয়।

## Rule 4

**AI is advisory unless explicitly proven otherwise**

AI recommendation-এর output human/backend business rules দ্বারা validate হবে।

## Rule 5

**Production readiness needs evidence**

Production-ready বলতে বোঝাবে:

```text
Code
+
Tests
+
Security
+
Monitoring
+
Deployment
+
Recovery
+
Business workflow
```

## Rule 6

**This document must be updated with every major architecture or business process change.**

---

# ৩৩. Change Log

## v2.0 — September 2026

এই update-এ:

- Customer feature inventory expanded
- Admin operations inventory expanded
- Commerce workflow documented
- Payment workflow separated from placeholder implementation
- Pricing/stock server-side trust boundary added
- Coupon/loyalty transactional requirements added
- Inventory reservation model added
- B2B/business account model added
- Emergency/medical workflow added
- Search scaling requirements added
- Analytics KPI framework added
- Backup/recovery requirements added
- CI/CD quality gates documented
- P0/P1/P2 production blockers added
- Existing code capabilities বনাম production-ready capability আলাদা করা হয়েছে
- Auth/social capability claims tightened
- AI responsibilities and safety boundaries clarified
- Production work process documented end-to-end

---

# ✅ Final Business Definition

**Paykari Bazar = Commerce + Wholesale + Logistics + Operations + Customer Retention + Emergency Services + AI Assistance**

Core business loop:

```text
Product
  ↓
Price
  ↓
Customer
  ↓
Order
  ↓
Payment
  ↓
Inventory
  ↓
Fulfillment
  ↓
Delivery
  ↓
Retention
  ↓
Repeat Purchase
```

AI, loyalty, reseller, healthcare, analytics এবং automation এই core loop-এর চারপাশে supporting ecosystem হিসেবে কাজ করবে।

**এই Blueprint-কে এখন থেকে feature list নয়, বরং product + business + engineering source-of-truth হিসেবে maintain করতে হবে।**
