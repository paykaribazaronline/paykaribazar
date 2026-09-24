/**
 * Paykari Bazar — REST / HTTP router for Cloud Functions.
 *
 * Exposes all Firebase Callable functions and Webhook endpoints over standard
 * Express routes so they can be hosted on Render.com, Vercel, or run locally
 * without requiring Google Cloud Blaze billing.
 */
import { Router, Request, Response } from "express";

// Callable Functions
import { provisionStaff } from "./admin/provisionStaff";
import { setUserRole } from "./admin/provisionRole";
import { runSeed } from "./admin/seedLocations";
import { calcOrder } from "./pricing/calcOrder";
import { reserveStock } from "./inventory/reserveStock";
import { releaseReservation } from "./inventory/releaseReservation";
import { createOrder } from "./orders/createOrder";
import { cancelOrder } from "./orders/cancelOrder";
import { redeemCoupon } from "./coupons/redeem";
import { bkashCreatePayment } from "./payments/bkash";
import { nagadCreatePayment } from "./payments/nagad";
import { sslczCreatePayment } from "./payments/sslcommerz";
import { recordBankPaymentRequest, verifyBankPayment } from "./payments/bank";
import { verifyPayment } from "./payments/verifyPayment";
import { refundPayment } from "./payments/refund";
import { searchProducts } from "./search/productSearch";
import { analyzePrescription } from "./health/prescriptionProcess";
import { onUserCreateCallable } from "./users/onUserCreate";

// Webhooks
import { bkashWebhook } from "./payments/webhooks/bkashWebhook";
import { nagadWebhook } from "./payments/webhooks/nagadWebhook";
import { sslcommerzWebhook } from "./payments/webhooks/sslcommerzWebhook";

export const apiRouter = Router();

// Callable registry
const callableMap: Record<string, (req: any, res: any) => Promise<any> | any> = {
  calcOrder: calcOrder as any,
  reserveStock: reserveStock as any,
  releaseReservation: releaseReservation as any,
  createOrder: createOrder as any,
  cancelOrder: cancelOrder as any,
  redeemCoupon: redeemCoupon as any,
  bkashCreatePayment: bkashCreatePayment as any,
  nagadCreatePayment: nagadCreatePayment as any,
  sslczCreatePayment: sslczCreatePayment as any,
  recordBankPaymentRequest: recordBankPaymentRequest as any,
  verifyBankPayment: verifyBankPayment as any,
  verifyPayment: verifyPayment as any,
  refundPayment: refundPayment as any,
  searchProducts: searchProducts as any,
  analyzePrescription: analyzePrescription as any,
  provisionStaff: provisionStaff as any,
  setUserRole: setUserRole as any,
  runSeed: runSeed as any,
  seedLocations: runSeed as any,
  onUserCreate: onUserCreateCallable as any,
};

// Dispatcher for callable functions:
// Firebase onCall expects POST with JSON { data: ... } and Authorization: Bearer <idToken>
apiRouter.all("/:functionName", async (req: Request, res: Response) => {
  const rawParam = req.params["functionName"];
  const functionName = Array.isArray(rawParam) ? rawParam[0] : rawParam;

  if (!functionName || !callableMap[functionName]) {
    res.status(404).json({
      error: {
        message: `Function '${functionName ?? ""}' not found. Available: ${Object.keys(callableMap).join(", ")}`,
        status: "NOT_FOUND",
      },
    });
    return;
  }

  const handler = callableMap[functionName]!;

  // If client sent a plain JSON body without Firebase's `{ data: ... }` wrapper,
  // wrap it automatically so the Firebase callable handler receives it transparently.
  if (req.method === "POST" && req.body && typeof req.body === "object" && !("data" in req.body)) {
    req.body = { data: req.body };
  }

  try {
    await handler(req, res);
  } catch (err: any) {
    console.error(`[apiRouter] Unhandled error in ${functionName}:`, err);
    if (!res.headersSent) {
      res.status(500).json({
        error: {
          message: err?.message ?? "Internal Server Error",
          status: "INTERNAL",
        },
      });
    }
  }
});

export const webhookRouter = Router();

// Webhook endpoints (public, signature-verified)
webhookRouter.all("/bkash", (req, res) => (bkashWebhook as any)(req, res));
webhookRouter.all("/nagad", (req, res) => (nagadWebhook as any)(req, res));
webhookRouter.all("/sslcommerz", (req, res) => (sslcommerzWebhook as any)(req, res));
