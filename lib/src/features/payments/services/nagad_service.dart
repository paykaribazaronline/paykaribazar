import '../../../core/services/cloud_functions_client.dart';
import '../models/payment_init.dart';
import '../models/payment_method.dart';

/// Thin wrapper around [CloudFunctionsClient.nagadCreatePayment].
class NagadService {
  NagadService({CloudFunctionsClient? cf}) : _cf = cf ?? cloudFunctionsClient;
  final CloudFunctionsClient _cf;

  Future<PaymentInit> initiate({required String orderId}) {
    return _cf.nagadCreatePayment(orderId: orderId);
  }

  PaymentProvider get provider => PaymentProvider.nagad;
}
