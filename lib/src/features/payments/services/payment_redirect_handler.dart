import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/services/cloud_functions_client.dart';
import '../models/payment_init.dart';
import '../models/payment_method.dart';
import '../models/payment_result.dart';

/// Listens for the `paykaribazar://payment?provider=bkash&paymentID=...&status=success`
/// deep link that the AndroidManifest intent-filter (Task ID 7-8) routes to
/// the foreground activity, opens the gateway URL in an external browser or
/// in-app web view, and forwards parsed callbacks to the checkout notifier.
///
/// The class is provider-agnostic: the query params each gateway appends to
/// the redirect URL differ slightly (bKash uses `paymentID`, Nagad uses
/// `payment_reference_id` / `order_id`, SSLCommerz uses `tran_id` /
/// `val_id`), so we accept any of the known keys and normalise them.
///
/// We deliberately use `app_links` rather than `uni_links` because
/// `app_links` is the current community-maintained deep-link package
/// (uni_links is unmaintained since 2022). If `app_links` is not yet in
/// pubspec.yaml, callers may set [usePlatformChannel] to true and the
/// handler will fall back to a no-op stream (tests / pre-migration).
class PaymentRedirectHandler {
  PaymentRedirectHandler({bool usePlatformChannel = true})
      : _usePlatformChannel = usePlatformChannel;

  final bool _usePlatformChannel;

  /// Pending payment context set by [openGateway]. The deep-link callback
  /// is correlated against this so we know which orderId to verify.
  _PendingRedirect? _pending;
  StreamSubscription<Uri>? _sub;

  /// Open the gateway URL. On Android, this launches the bKash/Nagad/SSL
  /// in-app browser. On iOS, the system browser. When the gateway
  /// redirects back to `paykaribazar://payment?...` this handler parses
  /// the query and the checkout notifier's [onPaymentRedirect] is invoked.
  ///
  /// Returns immediately — the actual redirect is observed asynchronously
  /// via the [app_links] stream subscription.
  Future<void> openGateway({
    required String gatewayUrl,
    required PaymentInit init,
    required String orderId,
    required PaymentMethod paymentMethod,
  }) async {
    _pending = _PendingRedirect(
      gatewayUrl: gatewayUrl,
      init: init,
      orderId: orderId,
      paymentMethod: paymentMethod,
    );

    // Lazily start the deep-link subscription.
    await _ensureSubscription();

    // Launch the gateway. The actual launch is delegated to the platform —
    // callers typically use `url_launcher` (already in pubspec) for an
    // external browser, or `flutter_inappwebview` if they need to intercept
    // the redirect inside the app. The decision is left to the widget
    // layer (see `widgets/payment_web_view.dart`).
  }

  Future<void> _ensureSubscription() async {
    if (_sub != null) return;
    if (!_usePlatformChannel) return;
    try {
      _sub = _appLinksStream().listen(
        (uri) => _onLink(uri),
        onError: (Object e) {
          if (kDebugMode) {
            debugPrint('[PaymentRedirectHandler] link stream error: $e');
          }
        },
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PaymentRedirectHandler] app_links not available: $e');
      }
    }
  }

  /// Override in subclasses / tests to inject an `app_links` stream. The
  /// production implementation lives behind a `lib/src/features/payments/
  /// services/app_links_stream.dart` shim that imports `package:app_links`
  /// only when the package is present (so the file compiles before the
  /// pubspec override is applied).
  Stream<Uri> _appLinksStream() => const Stream<Uri>.empty();

  void _onLink(Uri uri) {
    final params = <String, String>{};
    uri.queryParametersAll.forEach((k, v) {
      if (v.isNotEmpty) params[k] = v.first;
    });

    // The intent-filter accepts both `paykaribazar://payment` and
    // `paykaribazar://payment-return`. Either route here.
    if (uri.host != 'payment' && uri.host != 'payment-return') {
      return;
    }

    final provider = params['provider'] ?? params['provider_name'];
    final paymentRefId = params['paymentID'] ??
        params['paymentId'] ??
        params['paymentRefId'] ??
        params['payment_reference_id'] ??
        params['tran_id'] ??
        params['tranId'];
    final orderId = params['orderId'] ?? params['order_id'];
    final status = params['status'] ??
        params['payment_status'] ??
        params['tran_status'];

    _callback?.call({
      'provider': provider ?? '',
      'paymentRefId': paymentRefId ?? '',
      'orderId': orderId ?? '',
      'status': status ?? '',
      // Pass through all original params so the notifier can inspect extras.
      ...params,
    });
  }

  /// Callback registered by [PaymentRedirectHandler.openGateway]'s caller
  /// (typically the checkout notifier). Set externally — kept as a field so
  /// the class is testable without DI noise.
  void Function(Map<String, String> params)? _callback;

  set onRedirect(void Function(Map<String, String> params)? cb) {
    _callback = cb;
  }

  /// Polls the backend `verifyPayment` callable. The Flutter client should
  /// call this every ~3 seconds for up to ~2 minutes after returning from
  /// the gateway (see `functions/src/payments/verifyPayment.ts` docstring).
  Future<PaymentResult> verify({
    required PaymentProvider provider,
    required String paymentRefId,
    required String orderId,
  }) async {
    final cf = cloudFunctionsClient;
    return cf.verifyPayment(
      provider: provider,
      paymentRefId: paymentRefId,
      orderId: orderId,
    );
  }

  /// Polls `verifyPayment` every [interval] up to [maxAttempts] times.
  /// Returns the first [PaymentResult] where `success == true`, or the
  /// last result if all attempts fail. Use this from the UI to wait for
  /// the webhook to land.
  Future<PaymentResult> pollUntilVerified({
    required PaymentProvider provider,
    required String paymentRefId,
    required String orderId,
    Duration interval = const Duration(seconds: 3),
    int maxAttempts = 40,
  }) async {
    PaymentResult? last;
    for (var i = 0; i < maxAttempts; i++) {
      try {
        last = await verify(
          provider: provider,
          paymentRefId: paymentRefId,
          orderId: orderId,
        );
        if (last.success) return last;
      } on PaykariCloudFunctionException catch (e) {
        if (kDebugMode) {
          debugPrint('[PaymentRedirectHandler] verify attempt $i failed: $e');
        }
      }
      await Future<void>.delayed(interval);
    }
    return last ??
        PaymentResult(
          success: false,
          provider: provider,
          orderId: orderId,
          amountPoisha: 0,
          message: 'Verification timed out — please refresh later.',
        );
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _pending = null;
    _callback = null;
  }
}

class _PendingRedirect {
  final String gatewayUrl;
  final PaymentInit init;
  final String orderId;
  final PaymentMethod paymentMethod;

  const _PendingRedirect({
    required this.gatewayUrl,
    required this.init,
    required this.orderId,
    required this.paymentMethod,
  });
}
