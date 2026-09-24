/// Reservation record produced by the `reserveStock` Cloud Function and
/// stored at `inventoryReservations/{reservationId}` (see `functions/src/
/// inventory/reserveStock.ts`). The client treats this as a read-only view
/// — `status` transitions (`reserved` → `released` | `committed` |
/// `expired`) are server-driven only.
class ReservationModel {
  final String reservationId;
  final String? orderId;
  final String userId;
  final List<ReservationLine> items;
  final int subtotalPoisha;
  final int deliveryFeePoisha;
  final int discountPoisha;
  final int grandTotalPoisha;
  final String? couponCode;
  final String? addressId;
  final String? businessId;
  final String pricingVersion;
  final String status;
  final DateTime createdAt;
  final DateTime expiresAt;

  const ReservationModel({
    required this.reservationId,
    required this.orderId,
    required this.userId,
    required this.items,
    required this.subtotalPoisha,
    required this.deliveryFeePoisha,
    required this.discountPoisha,
    required this.grandTotalPoisha,
    required this.couponCode,
    required this.addressId,
    required this.businessId,
    required this.pricingVersion,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
  });

  factory ReservationModel.fromMap(Map<String, dynamic> map,
      {required String id}) {
    final items = (map['items'] as List<dynamic>? ?? const [])
        .map((e) => ReservationLine.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList(growable: false);

    final createdAtRaw = map['createdAt'];
    final expiresAtRaw = map['expiresAt'];

    return ReservationModel(
      reservationId: id,
      orderId: map['orderId'] as String?,
      userId: (map['userId'] as String?) ?? '',
      items: items,
      subtotalPoisha: (map['subtotalPoisha'] as num?)?.toInt() ?? 0,
      deliveryFeePoisha: (map['deliveryFeePoisha'] as num?)?.toInt() ?? 0,
      discountPoisha: (map['discountPoisha'] as num?)?.toInt() ?? 0,
      grandTotalPoisha: (map['grandTotalPoisha'] as num?)?.toInt() ?? 0,
      couponCode: map['couponCode'] as String?,
      addressId: map['addressId'] as String?,
      businessId: map['businessId'] as String?,
      pricingVersion: (map['pricingVersion'] as String?) ?? 'v1',
      status: (map['status'] as String?) ?? 'reserved',
      createdAt: _toDate(createdAtRaw) ?? DateTime.now(),
      expiresAt: _toDate(expiresAtRaw) ?? DateTime.now(),
    );
  }

  bool get isActive => status == 'reserved';
  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get isCommitted => status == 'committed';

  static DateTime? _toDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    // Firestore Timestamps
    if (v is DateTime) return v;
    final ms = v is num
        ? v.toInt()
        : (v is Map && v['seconds'] is num)
            ? (v['seconds'] as num).toInt() * 1000
            : null;
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
}

class ReservationLine {
  final String productId;
  final String name;
  final String nameBn;
  final String sku;
  final String imageUrl;
  final int unitPricePoisha;
  final int quantity;
  final int lineTotalPoisha;
  final String tierApplied;

  const ReservationLine({
    required this.productId,
    required this.name,
    required this.nameBn,
    required this.sku,
    required this.imageUrl,
    required this.unitPricePoisha,
    required this.quantity,
    required this.lineTotalPoisha,
    required this.tierApplied,
  });

  factory ReservationLine.fromMap(Map<String, dynamic> map) {
    return ReservationLine(
      productId: (map['productId'] as String?) ?? '',
      name: (map['name'] as String?) ?? '',
      nameBn: (map['nameBn'] as String?) ?? '',
      sku: (map['sku'] as String?) ?? '',
      imageUrl: (map['imageUrl'] as String?) ?? '',
      unitPricePoisha: (map['unitPricePoisha'] as num?)?.toInt() ?? 0,
      quantity: (map['quantity'] as num?)?.toInt() ?? 0,
      lineTotalPoisha: (map['lineTotalPoisha'] as num?)?.toInt() ?? 0,
      tierApplied: (map['tierApplied'] as String?) ?? 'retail',
    );
  }
}
