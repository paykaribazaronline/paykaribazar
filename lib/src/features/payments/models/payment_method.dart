/// All payment methods supported by the Paykari Bazar client. The `wireName`
/// matches the `paymentMethod` field the backend `createOrder` callable
/// accepts (see `functions/src/orders/createOrder.ts`).
enum PaymentMethod {
  bkash,
  nagad,
  sslcommerz,
  bankTransfer,
  cod;

  /// Wire format expected by the backend. MUST match `METHODS` in
  /// `functions/src/orders/createOrder.ts`.
  String get wireName {
    switch (this) {
      case PaymentMethod.bkash:
        return 'bkash';
      case PaymentMethod.nagad:
        return 'nagad';
      case PaymentMethod.sslcommerz:
        return 'sslcommerz';
      case PaymentMethod.bankTransfer:
        return 'bank_transfer';
      case PaymentMethod.cod:
        return 'cod';
    }
  }

  /// English label for UI.
  String get label {
    switch (this) {
      case PaymentMethod.bkash:
        return 'bKash';
      case PaymentMethod.nagad:
        return 'Nagad';
      case PaymentMethod.sslcommerz:
        return 'Card / Bank';
      case PaymentMethod.bankTransfer:
        return 'Bank Transfer';
      case PaymentMethod.cod:
        return 'Cash on Delivery';
    }
  }

  /// Bangla label for UI.
  String get banglaLabel {
    switch (this) {
      case PaymentMethod.bkash:
        return 'বিকাশ';
      case PaymentMethod.nagad:
        return 'নগদ';
      case PaymentMethod.sslcommerz:
        return 'কার্ড / ব্যাংক';
      case PaymentMethod.bankTransfer:
        return 'ব্যাংক ট্রান্সফার';
      case PaymentMethod.cod:
        return 'ক্যাশ অন ডেলিভারি';
    }
  }

  /// Material icon name (UI uses [Icons] — we expose the glyph name so the
  /// widget layer can map without a switch).
  String get icon {
    switch (this) {
      case PaymentMethod.bkash:
        return 'account_balance_wallet';
      case PaymentMethod.nagad:
        return 'mobile_friendly';
      case PaymentMethod.sslcommerz:
        return 'credit_card';
      case PaymentMethod.bankTransfer:
        return 'account_balance';
      case PaymentMethod.cod:
        return 'local_shipping';
    }
  }

  /// True for methods that return a `gatewayUrl` the UI must launch in a
  /// web view. Bank transfer and COD never redirect.
  bool get isGateway =>
      this == PaymentMethod.bkash ||
      this == PaymentMethod.nagad ||
      this == PaymentMethod.sslcommerz;

  /// Cast back to the provider enum used by [PaymentInit] / [PaymentResult].
  PaymentProvider get toProvider {
    switch (this) {
      case PaymentMethod.bkash:
        return PaymentProvider.bkash;
      case PaymentMethod.nagad:
        return PaymentProvider.nagad;
      case PaymentMethod.sslcommerz:
        return PaymentProvider.sslcommerz;
      case PaymentMethod.bankTransfer:
      case PaymentMethod.cod:
        throw StateError('$name does not have a PaymentProvider');
    }
  }
}

/// Internal provider enum — excludes bank + cod since neither has a
/// server-side `verifyPayment` callable (bank is verified by admin; cod has
/// no payment at all).
enum PaymentProvider {
  bkash,
  nagad,
  sslcommerz;

  String get wireName {
    switch (this) {
      case PaymentProvider.bkash:
        return 'bkash';
      case PaymentProvider.nagad:
        return 'nagad';
      case PaymentProvider.sslcommerz:
        return 'sslcommerz';
    }
  }
}
