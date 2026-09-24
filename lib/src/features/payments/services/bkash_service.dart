import '../../../core/services/cloud_functions_client.dart';
import '../models/payment_init.dart';
import '../models/payment_method.dart';

/// Thin wrapper around [CloudFunctionsClient.bkashCreatePayment]. Kept as a
/// separate class so feature modules can inject a mock in tests, and so the
/// checkout flow can construct each provider lazily rather than always
/// binding all four.
class BkashService {
  BkashService({CloudFunctionsClient? cf}) : _cf = cf ?? cloudFunctionsClient;
  final CloudFunctionsClient _cf;

  Future<PaymentInit> initiate({
    required String orderId,
    int? amountPoisha,
  }) {
    return _cf.bkashCreatePayment(
      orderId: orderId,
      amountPoisha: amountPoisha,
    );
  }

  PaymentProvider get provider => PaymentProvider.bkash;
}
