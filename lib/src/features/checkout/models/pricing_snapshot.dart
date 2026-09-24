/// Server-signed pricing snapshot produced by the `calcOrder` Cloud Function
/// and round-tripped through `reserveStock` → `createOrder`. All money fields
/// are integer **poisha** (1 taka = 100 poisha). The client must never
/// recompute any of these values — it only echoes them back to the backend
/// alongside the HMAC `signature`.
///
/// The full server-side schema lives in
/// `functions/src/pricing/calcOrder.ts` (interface `PricingSnapshot`). The
/// JSON wire format is intentionally compact so the canonical JSON used for
/// the HMAC is byte-stable across calls.
library;

/// A single line in a pricing snapshot. Mirrors `LineSnapshot` on the backend.
class LineItem {
  final String productId;
  final String name;
  final String nameBn;
  final String sku;
  final String imageUrl;
  final int unitPricePoisha;
  final int quantity;
  final int lineTotalPoisha;
  final String tierApplied;
  final int stockAtCalc;
  final int reservedStockAtCalc;

  const LineItem({
    required this.productId,
    required this.name,
    required this.nameBn,
    required this.sku,
    required this.imageUrl,
    required this.unitPricePoisha,
    required this.quantity,
    required this.lineTotalPoisha,
    required this.tierApplied,
    required this.stockAtCalc,
    required this.reservedStockAtCalc,
  });

  factory LineItem.fromJson(Map<String, dynamic> json) {
    return LineItem(
      productId: json['productId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      nameBn: json['nameBn'] as String? ?? '',
      sku: json['sku'] as String? ?? '',
      imageUrl: json['imageUrl'] as String? ?? '',
      unitPricePoisha: (json['unitPricePoisha'] as num?)?.toInt() ?? 0,
      quantity: (json['quantity'] as num?)?.toInt() ?? 0,
      lineTotalPoisha: (json['lineTotalPoisha'] as num?)?.toInt() ?? 0,
      tierApplied: json['tierApplied'] as String? ?? 'retail',
      stockAtCalc: (json['stockAtCalc'] as num?)?.toInt() ?? 0,
      reservedStockAtCalc: (json['reservedStockAtCalc'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'name': name,
        'nameBn': nameBn,
        'sku': sku,
        'imageUrl': imageUrl,
        'unitPricePoisha': unitPricePoisha,
        'quantity': quantity,
        'lineTotalPoisha': lineTotalPoisha,
        'tierApplied': tierApplied,
        'stockAtCalc': stockAtCalc,
        'reservedStockAtCalc': reservedStockAtCalc,
      };
}

/// The signed snapshot. `signature` is the HMAC-SHA256 of the canonical JSON
/// of [toJson]'s output (minus the `signature` field itself, which the
/// backend strips before verifying). The `pricingVersion` field is included
/// so the client can route future snapshots to the right code path.
class PricingSnapshot {
  final List<LineItem> items;
  final int subtotalPoisha;
  final int deliveryFeePoisha;
  final int discountPoisha;
  final int grandTotalPoisha;
  final String pricingVersion;
  final DateTime expiresAt;
  final String signature;
  final String? couponCode;
  final String? addressId;
  final String? businessId;

  const PricingSnapshot({
    required this.items,
    required this.subtotalPoisha,
    required this.deliveryFeePoisha,
    required this.discountPoisha,
    required this.grandTotalPoisha,
    required this.pricingVersion,
    required this.expiresAt,
    required this.signature,
    this.couponCode,
    this.addressId,
    this.businessId,
  });

  /// Build from the wire payload returned by `calcOrder`. The backend returns
  /// the top-level fields (subtotal, discount, …) as floats in taka, plus an
  /// embedded `snapshot` object that already uses integer poisha. We prefer
  /// the embedded snapshot for fidelity, then attach `signature` and
  /// `pricingVersion` from the envelope.
  factory PricingSnapshot.fromCalcOrderResponse(Map<String, dynamic> json) {
    final embedded = json['snapshot'];
    final snap = embedded is Map<String, dynamic>
        ? embedded
        : <String, dynamic>{};

    final itemsList = (snap['items'] as List<dynamic>? ?? const [])
        .map((e) => LineItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(growable: false);

    final expiresAtMs = (snap['expiresAtMs'] as num?)?.toInt() ??
        (json['expiresAt'] as num?)?.toInt() ??
        0;

    return PricingSnapshot(
      items: itemsList,
      subtotalPoisha: (snap['subtotalPoisha'] as num?)?.toInt() ??
          _takaToPoisha(json['subtotal']),
      deliveryFeePoisha: (snap['deliveryFeePoisha'] as num?)?.toInt() ??
          _takaToPoisha(json['deliveryFee']),
      discountPoisha: (snap['discountPoisha'] as num?)?.toInt() ??
          _takaToPoisha(json['discount']),
      grandTotalPoisha: (snap['grandTotalPoisha'] as num?)?.toInt() ??
          _takaToPoisha(json['grandTotal']),
      pricingVersion: (json['pricingVersion'] as String?) ??
          (snap['version'] as String?) ??
          'v1',
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAtMs),
      signature: (json['signature'] as String?) ?? '',
      couponCode: (snap['couponCode'] as String?) ??
          (json['couponCode'] as String?),
      addressId: (snap['addressId'] as String?) ?? (json['addressId'] as String?),
      businessId:
          (snap['businessId'] as String?) ?? (json['businessId'] as String?),
    );
  }

  /// Serialise back to the wire format expected by `reserveStock` and
  /// `createOrder`. The backend re-computes the HMAC over this exact shape
  /// (canonical JSON, sorted keys) and rejects if it doesn't match.
  Map<String, dynamic> toJson() => {
        'version': pricingVersion,
        'items': items.map((e) => e.toJson()).toList(),
        'subtotalPoisha': subtotalPoisha,
        'deliveryFeePoisha': deliveryFeePoisha,
        'discountPoisha': discountPoisha,
        'grandTotalPoisha': grandTotalPoisha,
        'couponCode': couponCode,
        'addressId': addressId,
        'businessId': businessId,
        'issuedAtMs': expiresAt
            .subtract(const Duration(minutes: 10))
            .millisecondsSinceEpoch,
        'expiresAtMs': expiresAt.millisecondsSinceEpoch,
      };

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Convenience: grand total in taka (read-only, for UI display only).
  double get grandTotalTaka => grandTotalPoisha / 100.0;

  static int _takaToPoisha(dynamic taka) {
    if (taka == null) return 0;
    if (taka is num) return (taka * 100).round();
    return (double.tryParse(taka.toString()) ?? 0).round() * 100;
  }
}
