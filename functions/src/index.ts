/**
 * Paykari Bazar — Cloud Functions (2nd gen, TypeScript) entry point.
 *
 * All callables and HTTPS webhooks are wired here. The admin SDK is
 * initialised with `applicationDefault()` inside `./admin.ts`, so no
 * secrets live in this repo — everything is supplied via Cloud Functions
 * env config / Secret Manager.
 *
 * Region: `asia-southeast1` (Singapore — closest GCP region to Bangladesh,
 * which has no GCP region of its own).
 *
 * Deploy:
 *   firebase deploy --only functions
 */

// ---- admin / shared setup -------------------------------------------------
// `./admin` initialises the Admin SDK at import time, before any function
// below runs. Importing for side-effects is intentional.
import "./admin";

// ---- callable & HTTPS function exports -----------------------------------

// User lifecycle
export { onUserCreate } from "./users/onUserCreate";

// Admin provisioning
export { provisionStaff } from "./admin/provisionStaff";
export { setUserRole } from "./admin/provisionRole";
export { runSeed } from "./admin/seedLocations";

// Pricing
export { calcOrder } from "./pricing/calcOrder";

// Inventory
export { reserveStock } from "./inventory/reserveStock";
export { releaseReservation } from "./inventory/releaseReservation";
// commitReservation is an internal helper (not a callable) but re-exported
// so unit tests can import it directly.
export { commitReservation } from "./inventory/commitReservation";

// Orders
export { createOrder } from "./orders/createOrder";
export { cancelOrder } from "./orders/cancelOrder";

// Coupons
export { redeemCoupon } from "./coupons/redeem";
export { redeemCouponInternal } from "./coupons/redeem";

// Payments — callables
export { bkashCreatePayment } from "./payments/bkash";
export { nagadCreatePayment } from "./payments/nagad";
export { sslczCreatePayment } from "./payments/sslcommerz";
export {
  recordBankPaymentRequest,
  verifyBankPayment,
} from "./payments/bank";
export { verifyPayment } from "./payments/verifyPayment";
export { refundPayment } from "./payments/refund";

// Payments — HTTPS webhooks (public, signature-verified)
export { bkashWebhook } from "./payments/webhooks/bkashWebhook";
export { nagadWebhook } from "./payments/webhooks/nagadWebhook";
export { sslcommerzWebhook } from "./payments/webhooks/sslcommerzWebhook";

// Search
export { searchProducts, buildSearchTokens } from "./search/productSearch";

// Healthcare / prescription
export { analyzePrescription } from "./health/prescriptionProcess";

// Audit (helper re-export; recordAudit is internal)
export { recordAudit } from "./audit/auditLog";
