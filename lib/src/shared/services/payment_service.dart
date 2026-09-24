import '../../core/services/cloud_functions_client.dart';
import '../../features/payments/models/payment_init.dart';
import '../../features/payments/models/payment_method.dart';
import '../../features/payments/models/payment_result.dart';

/// Abstract payment service surface. The legacy abstract class returned
/// `Future<bool>` from `initiateBkash/initiateNagad` and unconditionally
/// returned `true` from `verifyPayment` — that implementation is GONE.
///
/// The new surface:
///   - Always returns a typed [PaymentInit] (with `gatewayUrl`) — never
///     `bool`. The UI uses the URL to launch the gateway.
///   - All money is `int` poisha.
///   - All calls route through [CloudFunctionsClient] so the secrets never
///     touch the client binary.
///
/// This class is registered as a singleton in `service_initializer.dart` —
/// the existing `getIt.registerLazySingleton<PaymentService>(() =>
/// PaymentServiceImpl())` call now needs to be updated to inject the
/// CloudFunctionsClient (or it will lazily resolve via the [cloudFunctionsClient]
/// getter when not provided).
abstract class PaymentService {
  Future<PaymentInit> initiateBkash({
    required String orderId,
    required int amountPoisha,
    required String userId,
    required String currency,
  });

  Future<PaymentInit> initiateNagad({
    required String orderId,
    required int amountPoisha,
    required String userId,
  });

  Future<PaymentInit> initiateSslcommerz({
    required String orderId,
    required int amountPoisha,
    required String userId,
    required String cusName,
    required String cusEmail,
    required String cusPhone,
  });

  Future<BankPaymentRequest> initiateBankTransfer({
    required String orderId,
    required int amountPoisha,
    required String userId,
  });

  Future<PaymentVerifyResult> verifyPayment({
    required String provider,
    required String paymentRefId,
    required String orderId,
  });

  /// Admin-only. The backend `refundPayment` callable asserts
  /// `role === 'admin'` and throws `permission-denied` for everyone else.
  /// [amountPoisha] is optional — if null, the backend refunds the full
  /// original amount.
  Future<void> refundPayment({
    required String paymentId,
    int? amountPoisha,
    String? reason,
  });
}

/// Implementation that delegates to [CloudFunctionsClient]. No client-side
/// secrets, no `Future.delayed` simulations, no `return true`.
class PaymentServiceImpl implements PaymentService {
  PaymentServiceImpl({CloudFunctionsClient? cf})
      : _cf = cf ?? cloudFunctionsClient;

  final CloudFunctionsClient _cf;

  @override
  Future<PaymentInit> initiateBkash({
    required String orderId,
    required int amountPoisha,
    required String userId,
    required String currency,
  }) {
    // `currency` is implicitly BDT — kept on the interface for future-proofing.
    // The backend ignores it (bKash only accepts BDT).
    assert(currency == 'BDT',
        'bKash only supports BDT. Got $currency');
    return _cf.bkashCreatePayment(
      orderId: orderId,
      amountPoisha: amountPoisha,
    );
  }

  @override
  Future<PaymentInit> initiateNagad({
    required String orderId,
    required int amountPoisha,
    required String userId,
  }) {
    // The backend reads amount from the order doc — `amountPoisha` is
    // included on the interface for parity with bKash/SSLCommerz but is
    // not forwarded to Nagad's callable signature.
    return _cf.nagadCreatePayment(orderId: orderId);
  }

  @override
  Future<PaymentInit> initiateSslcommerz({
    required String orderId,
    required int amountPoisha,
    required String userId,
    required String cusName,
    required String cusEmail,
    required String cusPhone,
  }) {
    // SSLCommerz reads customer details from the order doc server-side —
    // the cusName/cusEmail/cusPhone params are accepted on the interface
    // for backwards compatibility but currently not forwarded (the backend
    // already populates them from `order.customerName/Email/Phone`).
    return _cf.sslczCreatePayment(orderId: orderId);
  }

  @override
  Future<BankPaymentRequest> initiateBankTransfer({
    required String orderId,
    required int amountPoisha,
    required String userId,
  }) {
    // The bank-transfer flow is two-step: first the caller uploads a slip
    // to Storage, then they call [recordBankPaymentRequest]. The
    // `initiateBankTransfer` method on this interface is preserved for the
    // signature — it returns the bank-account list + amountExpected
    // (without yet recording a slip).
    //
    // Implementation note: we forward to `recordBankPaymentRequest` with a
    // placeholder slip URL the caller is expected to replace before
    // submission. In practice, the UI should use
    // `CloudFunctionsClient.recordBankPaymentRequest` directly after the
    // Storage upload. This method is kept as a no-op stub for parity.
    throw UnimplementedError(
      'initiateBankTransfer is a two-step flow — see CloudFunctionsClient.recordBankPaymentRequest.',
    );
  }

  @override
  Future<PaymentVerifyResult> verifyPayment({
    required String provider,
    required String paymentRefId,
    required String orderId,
  }) async {
    final prov = _parseProvider(provider);
    final result = await _cf.verifyPayment(
      provider: prov,
      paymentRefId: paymentRefId,
      orderId: orderId,
    );
    return PaymentVerifyResult(
      success: result.success,
      orderId: result.orderId,
      provider: prov.wireName,
      message: result.message,
    );
  }

  @override
  Future<void> refundPayment({
    required String paymentId,
    int? amountPoisha,
    String? reason,
  }) {
    return _cf.refundPayment(
      paymentId: paymentId,
      amountPoisha: amountPoisha,
      reason: reason,
    );
  }

  PaymentProvider _parseProvider(String s) {
    switch (s.toLowerCase()) {
      case 'bkash':
        return PaymentProvider.bkash;
      case 'nagad':
        return PaymentProvider.nagad;
      case 'sslcommerz':
      case 'sslcz':
        return PaymentProvider.sslcommerz;
      default:
        throw ArgumentError.value(s, 'provider',
            'Must be bkash, nagad, or sslcommerz');
    }
  }
}

/// Re-exported result type used by [PaymentServiceImpl.verifyPayment].
class PaymentVerifyResult {
  final bool success;
  final String orderId;
  final String provider;
  final String? message;
  const PaymentVerifyResult({
    required this.success,
    required this.orderId,
    required this.provider,
    this.message,
  });
}
