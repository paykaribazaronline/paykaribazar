class HubPaths {
  static const String root = 'hub';
  static const String users = 'users';
  static const String orders = 'orders';
  static const String products = '$root/data/products';
  static const String categories = '$root/data/categories';
  static const String stores = '$root/data/stores';
  static const String locations = '$root/data/locations';
  static const String notifications = 'notifications';
  static const String secretsDoc = 'settings/secrets';
  static const String configDoc = 'settings/app_config';
  static const String loyaltyDoc = 'settings/loyalty';
  static const String localizationDoc = 'settings/localization';
  static const String staffCommissions = 'staff_commissions';
  static const String donors = '$root/emergency/donors';
  static const String doctors = '$root/emergency/doctors';
  static const String helplines = '$root/emergency/helplines';
  static const String privateChats = 'private_chats';
  static const String coupons = 'settings/coupons';
  static const String deliveryZones = 'settings/delivery_zones';
  
  // Static Content Paths
  static const String faqs = 'settings/faqs';
  static const String aboutUs = 'settings/about_us';
  static const String termsConditions = 'settings/terms_conditions';
  static const String partners = 'settings/partners';
  static const String staffList = 'settings/staff_list';
  static const String howToUse = 'settings/how_to_use';

  // Interactive Collections
  static const String reviews = 'reviews';
  static const String applications = 'applications';

  // ---------------------------------------------------------------------------
  // New top-level collections added in Task ID 9 backend + Task ID 7-8 rules.
  // These mirror the Firestore path layout the backend callables write to
  // and that the locked-down `firestore.rules` grant server-only writes on.
  // ---------------------------------------------------------------------------

  /// `productPrices/{productId}` — B2B contract prices (server-only writes).
  /// Read by `calcOrder` to resolve the contract price tier.
  static const String productPrices = '$root/data/productPrices';

  /// `inventoryReservations/{reservationId}` — atomic inventory holds
  /// produced by the `reserveStock` callable. Owner-or-staff read,
  /// server-only writes.
  static const String inventoryReservations = 'inventoryReservations';

  /// `payments/{paymentId}` — payment records for bKash / Nagad / SSLCommerz
  /// / bank transfers. Owner-or-staff read, server-only writes.
  static const String payments = 'payments';

  /// `businesses/{businessId}` — B2B business profiles (reseller companies).
  static const String businesses = 'businesses';

  /// `auditLogs/{logId}` — server-side audit trail for all trust-boundary
  /// operations (reservation create/release, order create/cancel, payment
  /// verify, refund). Authenticated create, admin read.
  static const String auditLogs = 'auditLogs';

  /// `prescriptions/{prescriptionId}` — prescription image analysis records
  /// produced by the `analyzePrescription` callable. Owner-or-staff read,
  /// owner create, staff update.
  static const String prescriptions = 'prescriptions';

  /// `paymentslips` is a STORAGE path (not a Firestore collection) — the
  /// bank-transfer flow uploads slips to
  /// `paymentslips/{userId}/{paymentId}.jpg`. The reference is kept here so
  /// the client-side Storage upload code can share a single source of truth
  /// for the bucket name.
  static const String paymentslipsStorage = 'paymentslips';

  /// `payments/{paymentId}/refunds/{refundId}` — refund sub-collection.
  /// Server-only writes; admin read.
  static const String refundsSub = 'refunds';
}
