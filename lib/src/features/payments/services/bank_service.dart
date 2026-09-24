import '../../../core/services/cloud_functions_client.dart';
import '../models/payment_result.dart';

/// Thin wrapper around [CloudFunctionsClient.recordBankPaymentRequest]. The
/// flow is two-step: the UI uploads the slip to Storage
/// (`paymentslips/{uid}/{paymentId}.jpg`) via the existing `MediaService`,
/// then calls [register] with the resulting https URL. The backend creates
/// a `payments/{paymentId}` doc with `status: 'pending_manual_verification'`
/// which an admin later approves via `verifyBankPayment`.
class BankService {
  BankService({CloudFunctionsClient? cf}) : _cf = cf ?? cloudFunctionsClient;
  final CloudFunctionsClient _cf;

  Future<BankPaymentResult> register({
    required String orderId,
    required String slipUrl,
    double? amountPaid,
    String? transferDate,
    String? senderAccount,
    String? note,
  }) async {
    final req = await _cf.recordBankPaymentRequest(
      orderId: orderId,
      slipUrl: slipUrl,
      amountPaid: amountPaid,
      transferDate: transferDate,
      senderAccount: senderAccount,
      note: note,
    );
    // The cloud_functions_client already returns BankPaymentRequest; convert
    // to the local BankPaymentResult view-model.
    return BankPaymentResult(
      paymentId: req.paymentId,
      status: req.status,
      banks: req.banks
          .map((b) => BankAccount.fromJson(b))
          .toList(growable: false),
      amountExpectedPoisha: req.amountExpectedPoisha,
    );
  }
}
