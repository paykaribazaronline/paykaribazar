import 'payment_method.dart';

/// Result of `verifyPayment` callable (see `functions/src/payments/
/// verifyPayment.ts`). The backend returns `{orderId, paymentStatus,
/// alreadyVerified, message?}`. We lift the canonical fields and expose
/// `success` as a convenience for the UI.
class PaymentResult {
  final bool success;
  final String? transactionId;
  final PaymentProvider provider;
  final String orderId;
  final int amountPoisha;
  final DateTime? verifiedAt;
  final String? message;

  const PaymentResult({
    required this.success,
    required this.provider,
    required this.orderId,
    required this.amountPoisha,
    this.transactionId,
    this.verifiedAt,
    this.message,
  });

  factory PaymentResult.fromJson(
    Map<String, dynamic> json, {
    required PaymentProvider provider,
  }) {
    final status = (json['paymentStatus'] as String?) ?? 'unpaid';
    return PaymentResult(
      success: status == 'paid',
      provider: provider,
      orderId: (json['orderId'] as String?) ?? '',
      amountPoisha: (json['amountPoisha'] as num?)?.toInt() ?? 0,
      transactionId: json['transactionId'] as String?,
      verifiedAt: null,
      message: json['message'] as String?,
    );
  }
}

/// Result of a bank-transfer slip submission. Returned by
/// `recordBankPaymentRequest` (see `functions/src/payments/bank.ts`).
class BankPaymentResult {
  final String paymentId;
  final String status;
  final List<BankAccount> banks;
  final int amountExpectedPoisha;

  const BankPaymentResult({
    required this.paymentId,
    required this.status,
    required this.banks,
    required this.amountExpectedPoisha,
  });

  factory BankPaymentResult.fromJson(Map<String, dynamic> json) {
    return BankPaymentResult(
      paymentId: (json['paymentId'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'pending_manual_verification',
      banks: ((json['banks'] as List<dynamic>?) ?? const [])
          .map((e) => BankAccount.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(growable: false),
      amountExpectedPoisha:
          (((json['amountExpected'] as num?) ?? 0).toDouble() * 100).round(),
    );
  }
}

class BankAccount {
  final String bank;
  final String account;
  final String? branch;
  final String? routing;

  const BankAccount({
    required this.bank,
    required this.account,
    this.branch,
    this.routing,
  });

  factory BankAccount.fromJson(Map<String, dynamic> json) {
    return BankAccount(
      bank: (json['bank'] as String?) ?? '',
      account: (json['account'] as String?) ?? '',
      branch: json['branch'] as String?,
      routing: json['routing'] as String?,
    );
  }
}
