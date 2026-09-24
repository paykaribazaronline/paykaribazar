import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/cloud_functions_client.dart';
import '../../payments/models/payment_method.dart';
import '../../payments/models/payment_result.dart';
import '../../payments/services/payment_redirect_handler.dart';
import '../models/pricing_snapshot.dart';
import '../services/checkout_service.dart';

/// State machine for the checkout flow. The UI watches this to render the
/// correct screen (pricing spinner, redirect handler, success / failure).
sealed class CheckoutState {
  const CheckoutState();
}

class CheckoutIdle extends CheckoutState {
  const CheckoutIdle();
}

class CheckoutPricing extends CheckoutState {
  const CheckoutPricing();
}

class CheckoutReserved extends CheckoutState {
  final PricingSnapshot snapshot;
  const CheckoutReserved(this.snapshot);
}

class CheckoutOrderCreated extends CheckoutState {
  final String orderId;
  final PricingSnapshot snapshot;
  const CheckoutOrderCreated(this.orderId, this.snapshot);
}

class CheckoutRedirecting extends CheckoutState {
  final String orderId;
  final String gatewayUrl;
  final PaymentMethod paymentMethod;
  const CheckoutRedirecting({
    required this.orderId,
    required this.gatewayUrl,
    required this.paymentMethod,
  });
}

class CheckoutVerifying extends CheckoutState {
  final String orderId;
  final PaymentMethod paymentMethod;
  const CheckoutVerifying(this.orderId, this.paymentMethod);
}

class CheckoutSuccess extends CheckoutState {
  final String orderId;
  final PaymentResult? paymentResult;
  const CheckoutSuccess(this.orderId, this.paymentResult);
}

class CheckoutFailed extends CheckoutState {
  final String reason;
  final String? banglaReason;
  const CheckoutFailed(this.reason, {this.banglaReason});
}

class CheckoutCancelled extends CheckoutState {
  const CheckoutCancelled();
}

class CheckoutNotifier extends StateNotifier<CheckoutState> {
  CheckoutNotifier(this._checkout, this._redirectHandler)
      : super(const CheckoutIdle()) {
    // Wire the redirect handler's deep-link callback to our own
    // [onPaymentRedirect] method. Without this, even with `app_links`
    // subscribed, the parsed redirect params would never reach the state
    // machine (the `_callback` field in PaymentRedirectHandler would stay
    // null and the link would be silently dropped).
    _redirectHandler.onRedirect = onPaymentRedirect;
  }

  final CheckoutService _checkout;
  final PaymentRedirectHandler _redirectHandler;

  /// In-flight checkout result, kept so [onPaymentRedirect] can call
  /// `verifyPayment` against the correct orderId/provider.
  CheckoutResult? _pending;

  @override
  void dispose() {
    // Cancel the deep-link subscription so we don't leak the stream or
    // deliver a redirect to a disposed notifier.
    _redirectHandler.onRedirect = null;
    unawaited(_redirectHandler.dispose());
    super.dispose();
  }

  Future<void> startCheckout(CheckoutRequest req) async {
    state = const CheckoutPricing();
    try {
      final result = await _checkout.checkout(req);
      _pending = result;

      if (result.requiresRedirect &&
          result.gatewayUrl != null &&
          result.paymentInit != null) {
        state = CheckoutRedirecting(
          orderId: result.orderId,
          gatewayUrl: result.gatewayUrl!,
          paymentMethod: result.paymentMethod,
        );
        // Hand off to the redirect handler — it will invoke [onPaymentRedirect]
        // when the deep link arrives.
        await _redirectHandler.openGateway(
          gatewayUrl: result.gatewayUrl!,
          init: result.paymentInit!,
          orderId: result.orderId,
          paymentMethod: result.paymentMethod,
        );
      } else if (result.paymentMethod == PaymentMethod.bankTransfer) {
        // No redirect — UI shows bank details and waits for slip upload.
        state = CheckoutOrderCreated(result.orderId, result.snapshot);
      } else if (result.paymentMethod == PaymentMethod.cod) {
        state = CheckoutSuccess(result.orderId, null);
      } else {
        state = CheckoutOrderCreated(result.orderId, result.snapshot);
      }
    } on PaykariCloudFunctionException catch (e) {
      state = CheckoutFailed(e.message, banglaReason: e.banglaMessage);
    } catch (e) {
      if (kDebugMode) debugPrint('[CheckoutNotifier] startCheckout failed: $e');
      state = CheckoutFailed(e.toString());
    }
  }

  /// Called by [PaymentRedirectHandler] when the gateway deep-link arrives.
  /// The handler has already extracted provider + paymentRefId + orderId
  /// from the URL query string.
  Future<void> onPaymentRedirect(Map<String, String> params) async {
    final pending = _pending;
    if (pending == null) {
      state = const CheckoutFailed('No checkout in progress.');
      return;
    }

    final status = params['status'] ?? params['payment_status'] ?? '';
    final provider = pending.paymentMethod.toProvider;

    if (status.toLowerCase() == 'cancel' ||
        status.toLowerCase() == 'cancelled') {
      state = const CheckoutCancelled();
      try {
        await _checkout.cancelCheckoutReservation(pending);
      } catch (_) {}
      return;
    }

    if (status.toLowerCase() == 'fail' || status.toLowerCase() == 'failed') {
      state = const CheckoutFailed('Payment failed at the gateway.');
      try {
        await _checkout.cancelCheckoutReservation(pending);
      } catch (_) {}
      return;
    }

    // success (or unknown) — verify server-side.
    state = CheckoutVerifying(pending.orderId, pending.paymentMethod);
    try {
      final init = pending.paymentInit;
      if (init == null) {
        state = const CheckoutFailed('Missing paymentInit — cannot verify.');
        return;
      }
      final result = await _redirectHandler.verify(
        provider: provider,
        paymentRefId: init.paymentRefId,
        orderId: pending.orderId,
      );
      if (result.success) {
        state = CheckoutSuccess(pending.orderId, result);
      } else {
        state = const CheckoutFailed(
          'Payment not yet verified — please wait while the server confirms.',
          banglaReason: 'পেমেন্ট যাচাই হচ্ছে। একটু পরে আবার দেখুন।',
        );
      }
    } on PaykariCloudFunctionException catch (e) {
      state = CheckoutFailed(e.message, banglaReason: e.banglaMessage);
    } catch (e) {
      state = CheckoutFailed(e.toString());
    }
  }

  /// Cancel an in-flight checkout — release the reservation + cancel order.
  Future<void> cancel() async {
    final pending = _pending;
    if (pending == null) {
      state = const CheckoutIdle();
      return;
    }
    try {
      await _checkout.cancelCheckoutReservation(pending);
    } catch (_) {}
    state = const CheckoutCancelled();
  }

  void reset() {
    _pending = null;
    state = const CheckoutIdle();
  }
}

/// Extension on [CheckoutService] that isolates the cleanup path used by the
/// notifier. Implemented as an extension so [CheckoutService] itself stays a
/// pure "happy path" orchestrator.
extension CheckoutServiceCleanup on CheckoutService {
  Future<void> cancelCheckoutReservation(CheckoutResult result) async {
    // Releasing the reservation also cancels the order (server-side).
    // We don't call cancelOrder directly because the order may not yet be
    // paid — releaseReservation handles both states correctly.
    try {
      // Use the cloud functions client via reflection-free direct call —
      // CheckoutService exposes its `_cf` only via construction; we route
      // through the singleton here.
      await cloudFunctionsClient.releaseReservation(result.reservationId,
          reason: 'user_cancelled_checkout');
    } catch (e) {
      // If release fails (e.g. already committed), fall back to cancelOrder
      // which the backend allows for unpaid orders.
      try {
        await cloudFunctionsClient.cancelOrder(result.orderId,
            reason: 'user_cancelled');
      } catch (_) {
        rethrow;
      }
    }
  }
}

final checkoutServiceProvider = Provider<CheckoutService>((ref) {
  return CheckoutService();
});

final paymentRedirectHandlerProvider = Provider<PaymentRedirectHandler>((ref) {
  return PaymentRedirectHandler();
});

final checkoutProvider =
    StateNotifierProvider<CheckoutNotifier, CheckoutState>((ref) {
  final checkout = ref.watch(checkoutServiceProvider);
  final handler = ref.watch(paymentRedirectHandlerProvider);
  return CheckoutNotifier(checkout, handler);
});
