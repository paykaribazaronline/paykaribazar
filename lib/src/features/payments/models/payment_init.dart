import 'payment_method.dart';

/// Result of initiating a payment on the backend. Returned by the
/// `bkashCreatePayment`, `nagadCreatePayment`, and `sslczCreatePayment`
/// Cloud Functions (see `functions/src/payments/_http.ts` —
/// `CreatePaymentResult` interface). The UI launches [gatewayUrl] in an
/// in-app web view and listens for the `paykaribazar://payment` deep link.
class PaymentInit {
  final PaymentProvider provider;
  final String gatewayUrl;
  final String paymentRefId;
  final String orderId;
  final int amountPoisha;
  final DateTime? expiresAt;

  const PaymentInit({
    required this.provider,
    required this.gatewayUrl,
    required this.paymentRefId,
    required this.orderId,
    required this.amountPoisha,
    this.expiresAt,
  });

  factory PaymentInit.fromJson(
    Map<String, dynamic> json, {
    required PaymentProvider provider,
  }) {
    return PaymentInit(
      provider: provider,
      gatewayUrl: (json['gatewayUrl'] as String?) ??
          (json['bkashURL'] as String?) ??
          '',
      paymentRefId: (json['paymentRefId'] as String?) ??
          (json['paymentID'] as String?) ??
          '',
      orderId: (json['orderId'] as String?) ?? '',
      amountPoisha: (json['amountPoisha'] as num?)?.toInt() ?? 0,
      expiresAt: null,
    );
  }

  Map<String, dynamic> toJson() => {
        'provider': provider.wireName,
        'gatewayUrl': gatewayUrl,
        'paymentRefId': paymentRefId,
        'orderId': orderId,
        'amountPoisha': amountPoisha,
        if (expiresAt != null)
          'expiresAt': expiresAt!.millisecondsSinceEpoch,
      };
}
