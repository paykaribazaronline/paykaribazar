import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/cloud_functions_client.dart';
import '../../commerce/services/order_service.dart' show CartItemRequest;
import '../models/pricing_snapshot.dart';
import '../../payments/models/payment_init.dart';
import '../../payments/models/payment_method.dart';

/// Request payload for [CheckoutService.checkout]. The caller supplies the
/// raw cart, a delivery address, an optional coupon, and the chosen payment
/// method. All money computation happens server-side.
class CheckoutRequest {
  final List<CartItemRequest> items;
  final String? addressId;
  final String? couponCode;
  final String? businessId;
  final PaymentMethod paymentMethod;

  /// Optional customer note appended to the order doc.
  final String? note;

  /// For SSLCommerz — the success/fail/cancel URLs the gateway should
  /// redirect to. Defaults are populated by the backend if omitted.
  final String? sslSuccessUrl;
  final String? sslFailUrl;
  final String? sslCancelUrl;

  /// For bank transfer — once the user has uploaded the slip, the caller
  /// invokes [CheckoutService.recordBankSlip] separately rather than going
  /// through [checkout]. This field is unused for the initial call.
  final String? bankSlipUrl;

  const CheckoutRequest({
    required this.items,
    required this.paymentMethod,
    this.addressId,
    this.couponCode,
    this.businessId,
    this.note,
    this.sslSuccessUrl,
    this.sslFailUrl,
    this.sslCancelUrl,
    this.bankSlipUrl,
  });
}

/// The end-of-checkout result handed back to the UI. For gateway flows
/// (bKash/Nagad/SSLCommerz) `gatewayUrl` is non-null and the UI must launch
/// it via `url_launcher` (or `flutter_inappwebview` to intercept the
/// `paykaribazar://` redirect). For COD, `gatewayUrl` is null and the order
/// is already `confirmed` server-side. For bank transfer, the order is
/// `pending_payment` and the UI must collect the slip upload before calling
/// [recordBankSlip].
class CheckoutResult {
  final String orderId;
  final String reservationId;
  final PricingSnapshot snapshot;
  final PaymentMethod paymentMethod;
  final PaymentInit? paymentInit;
  final String? gatewayUrl;

  const CheckoutResult({
    required this.orderId,
    required this.reservationId,
    required this.snapshot,
    required this.paymentMethod,
    this.paymentInit,
    this.gatewayUrl,
  });

  bool get requiresRedirect =>
      gatewayUrl != null && gatewayUrl!.isNotEmpty && paymentMethod.isGateway;
}

/// Orchestrates the secure checkout flow:
///   1. `calcOrder` → signed [PricingSnapshot]
///   2. `reserveStock(snapshot)` → reservationId
///   3. `createOrder(snapshot, reservationId, addressId, paymentMethod)` → orderId
///   4. Initiate the chosen payment provider → gateway URL
///
/// The UI hands the [CheckoutResult] to [PaymentRedirectHandler] which opens
/// the gateway, listens for the `paykaribazar://payment` deep link, then
/// polls `verifyPayment` until the order is `paid`.
class CheckoutService {
  CheckoutService({CloudFunctionsClient? cf, FirebaseAuth? auth})
      : _cf = cf ?? cloudFunctionsClient,
        _auth = auth ?? FirebaseAuth.instance;

  final CloudFunctionsClient _cf;
  final FirebaseAuth _auth;

  Future<CheckoutResult> checkout(CheckoutRequest req) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('User must be authenticated before checkout.');
    }

    // 1. Pricing snapshot — server-computed, signed.
    final snapshot = await _cf.calcOrder(
      items: req.items.map((i) => i.toJson()).toList(growable: false),
      addressId: req.addressId,
      couponCode: req.couponCode,
      businessId: req.businessId,
    );
    if (snapshot.isExpired) {
      throw StateError('Pricing snapshot already expired.');
    }

    // 2. Reserve inventory atomically. If this throws, the UI shows a
    //    "stock changed" message and the user retries.
    final reservation = await _cf.reserveStock(snapshot);

    // 3. Create the order doc (server is the source of truth for totals).
    String orderId;
    try {
      orderId = await _cf.createOrder(
        snap: snapshot,
        reservationId: reservation.reservationId,
        addressId: req.addressId,
        paymentMethod: req.paymentMethod,
        note: req.note,
      );
    } catch (e) {
      // Best-effort cleanup: release the reservation so the inventory is
      // not held for 15 minutes if order creation failed.
      if (kDebugMode) {
        debugPrint('[CheckoutService] createOrder failed — releasing '
            'reservation ${reservation.reservationId}: $e');
      }
      try {
        await _cf.releaseReservation(reservation.reservationId,
            reason: 'checkout_failed_order_creation');
      } catch (_) {}
      rethrow;
    }

    // 4. Initiate payment (or no-op for COD / bank-transfer slip upload).
    PaymentInit? init;
    String? gatewayUrl;

    switch (req.paymentMethod) {
      case PaymentMethod.bkash:
        init = await _cf.bkashCreatePayment(orderId: orderId);
        gatewayUrl = init.gatewayUrl;
      case PaymentMethod.nagad:
        init = await _cf.nagadCreatePayment(orderId: orderId);
        gatewayUrl = init.gatewayUrl;
      case PaymentMethod.sslcommerz:
        init = await _cf.sslczCreatePayment(
          orderId: orderId,
          successUrl: req.sslSuccessUrl,
          failUrl: req.sslFailUrl,
          cancelUrl: req.sslCancelUrl,
        );
        gatewayUrl = init.gatewayUrl;
      case PaymentMethod.bankTransfer:
        // No gateway URL — the UI shows the bank account list and waits for
        // the user to upload a slip via [recordBankSlip].
        gatewayUrl = null;
      case PaymentMethod.cod:
        // COD: order is created with status `pending_payment` server-side;
        // the admin flips it to `confirmed` on dispatch.
        gatewayUrl = null;
    }

    return CheckoutResult(
      orderId: orderId,
      reservationId: reservation.reservationId,
      snapshot: snapshot,
      paymentMethod: req.paymentMethod,
      paymentInit: init,
      gatewayUrl: gatewayUrl,
    );
  }

  /// After a bank transfer slip has been uploaded to Storage
  /// (`paymentslips/{uid}/{paymentId}.jpg`) by the caller, register the
  /// pending-verification record with the backend.
  Future<void> recordBankSlip({
    required String orderId,
    required String slipUrl,
    double? amountPaid,
    String? transferDate,
    String? senderAccount,
    String? note,
  }) async {
    await _cf.recordBankPaymentRequest(
      orderId: orderId,
      slipUrl: slipUrl,
      amountPaid: amountPaid,
      transferDate: transferDate,
      senderAccount: senderAccount,
      note: note,
    );
  }
}
