import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/cloud_functions_client.dart';
import '../models/payment_init.dart';
import '../models/payment_method.dart';
import '../models/payment_result.dart';
import '../services/payment_redirect_handler.dart';

/// Sealed state for the payment flow. The [CheckoutNotifier] delegates the
/// gateway redirect + verify steps here so the UI can drive them
/// independently (e.g. retry verify, dismiss redirect).
sealed class PaymentState {
  const PaymentState();
}

class PaymentIdle extends PaymentState {
  const PaymentIdle();
}

class PaymentInitiating extends PaymentState {
  final PaymentMethod method;
  const PaymentInitiating(this.method);
}

class PaymentAwaitingRedirect extends PaymentState {
  final PaymentInit init;
  const PaymentAwaitingRedirect(this.init);
}

class PaymentVerifying extends PaymentState {
  final PaymentProvider provider;
  final String paymentRefId;
  final String orderId;
  const PaymentVerifying(this.provider, this.paymentRefId, this.orderId);
}

class PaymentSuccess extends PaymentState {
  final PaymentResult result;
  const PaymentSuccess(this.result);
}

class PaymentFailed extends PaymentState {
  final String reason;
  final String? banglaReason;
  const PaymentFailed(this.reason, {this.banglaReason});
}

class PaymentCancelled extends PaymentState {
  const PaymentCancelled();
}

class PaymentNotifier extends StateNotifier<PaymentState> {
  PaymentNotifier(this._handler) : super(const PaymentIdle()) {
    // Wire the redirect handler's deep-link callback to our own [onRedirect]
    // method. Without this, parsed redirect params from `app_links` would
    // never reach the state machine (the `_callback` field in
    // PaymentRedirectHandler would stay null and the link would be dropped).
    _handler.onRedirect = onRedirect;
  }

  final PaymentRedirectHandler _handler;
  PaymentInit? _active;

  @override
  void dispose() {
    // Detach the callback and cancel the deep-link subscription so a
    // redirect that arrives after the notifier is gone doesn't call
    // `setState`-equivalent on a disposed StateNotifier.
    _handler.onRedirect = null;
    unawaited(_handler.dispose());
    super.dispose();
  }

  Future<void> initiate({
    required PaymentInit init,
    required PaymentMethod method,
  }) async {
    _active = init;
    state = PaymentAwaitingRedirect(init);
    try {
      await _handler.openGateway(
        gatewayUrl: init.gatewayUrl,
        init: init,
        orderId: init.orderId,
        paymentMethod: method,
      );
    } on PaykariCloudFunctionException catch (e) {
      state = PaymentFailed(e.message, banglaReason: e.banglaMessage);
    } catch (e) {
      if (kDebugMode) debugPrint('[PaymentNotifier] openGateway failed: $e');
      state = PaymentFailed(e.toString());
    }
  }

  Future<void> onRedirect(Map<String, String> params) async {
    final active = _active;
    if (active == null) {
      state = const PaymentFailed('No active payment.');
      return;
    }
    final status = (params['status'] ?? '').toLowerCase();
    if (status == 'cancel' || status == 'cancelled') {
      state = const PaymentCancelled();
      return;
    }
    if (status == 'fail' || status == 'failed') {
      state = const PaymentFailed('Payment failed at the gateway.');
      return;
    }

    state = PaymentVerifying(active.provider, active.paymentRefId, active.orderId);
    try {
      final result = await _handler.pollUntilVerified(
        provider: active.provider,
        paymentRefId: active.paymentRefId,
        orderId: active.orderId,
      );
      if (result.success) {
        state = PaymentSuccess(result);
      } else {
        state = PaymentFailed(
          result.message ?? 'Payment not yet verified.',
          banglaReason: 'পেমেন্ট যাচাই হচ্ছে। একটু পরে আবার দেখুন।',
        );
      }
    } on PaykariCloudFunctionException catch (e) {
      state = PaymentFailed(e.message, banglaReason: e.banglaMessage);
    } catch (e) {
      state = PaymentFailed(e.toString());
    }
  }

  void reset() {
    _active = null;
    state = const PaymentIdle();
  }
}

final paymentNotifierProvider =
    StateNotifierProvider<PaymentNotifier, PaymentState>((ref) {
  return PaymentNotifier(PaymentRedirectHandler());
});
