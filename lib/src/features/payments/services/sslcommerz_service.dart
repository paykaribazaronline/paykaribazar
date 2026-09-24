import '../../../core/services/cloud_functions_client.dart';
import '../models/payment_init.dart';
import '../models/payment_method.dart';

/// Thin wrapper around [CloudFunctionsClient.sslczCreatePayment].
class SslcommerzService {
  SslcommerzService({CloudFunctionsClient? cf}) : _cf = cf ?? cloudFunctionsClient;
  final CloudFunctionsClient _cf;

  Future<PaymentInit> initiate({
    required String orderId,
    String? successUrl,
    String? failUrl,
    String? cancelUrl,
  }) {
    return _cf.sslczCreatePayment(
      orderId: orderId,
      successUrl: successUrl,
      failUrl: failUrl,
      cancelUrl: cancelUrl,
    );
  }

  PaymentProvider get provider => PaymentProvider.sslcommerz;
}
