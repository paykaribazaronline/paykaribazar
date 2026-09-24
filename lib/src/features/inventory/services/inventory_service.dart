import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/constants/paths.dart';
import '../../../core/services/cloud_functions_client.dart';
import '../models/reservation_model.dart';

/// Client-side access to the server-authoritative inventory layer. All
/// mutating operations (`reserveStock`, `releaseReservation`) are delegated
/// to the [CloudFunctionsClient] so the client never writes to Firestore
/// directly. Reads (`watchReservedStock`, `getReservation`) use plain
/// Firestore streams — the rules allow read access for owners/staff.
class InventoryService {
  InventoryService({
    CloudFunctionsClient? cf,
    FirebaseFirestore? firestore,
  })  : _cf = cf ?? cloudFunctionsClient,
        _db = firestore ?? FirebaseFirestore.instance;

  final CloudFunctionsClient _cf;
  final FirebaseFirestore _db;

  /// Watches `products/{productId}.reservedStock` so the UI can show a live
  /// "X reserved" indicator. The stream emits `0` if the doc or field is
  /// missing. Reads are public per the new `firestore.rules`.
  Stream<int> watchReservedStock(String productId) {
    return _db
        .collection(HubPaths.products)
        .doc(productId)
        .snapshots()
        .map((snap) {
      if (!snap.exists) return 0;
      final data = snap.data() ?? const <String, dynamic>{};
      return (data['reservedStock'] as num?)?.toInt() ?? 0;
    });
  }

  /// Watches the full product doc so the UI can show real-time stock +
  /// reservedStock + soldStock without polling.
  Stream<({int stock, int reserved, int sold})> watchStockLedger(
      String productId) {
    return _db
        .collection(HubPaths.products)
        .doc(productId)
        .snapshots()
        .map((snap) {
      final d = snap.data() ?? const <String, dynamic>{};
      return (
        stock: (d['stock'] as num?)?.toInt() ?? 0,
        reserved: (d['reservedStock'] as num?)?.toInt() ?? 0,
        sold: (d['soldStock'] as num?)?.toInt() ?? 0,
      );
    });
  }

  /// Fetches a reservation doc by id. Returns null if not found / no read
  /// permission (rules limit reads to owner + staff).
  Future<ReservationModel?> getReservation(String reservationId) async {
    final snap = await _db
        .collection(HubPaths.inventoryReservations)
        .doc(reservationId)
        .get();
    if (!snap.exists) return null;
    return ReservationModel.fromMap(
      snap.data() ?? const <String, dynamic>{},
      id: snap.id,
    );
  }

  /// Convenience: release a reservation owned by the caller. Used by the
  /// checkout flow when the user navigates away mid-checkout.
  Future<void> release(String reservationId,
      {String reason = 'user_cancelled'}) {
    return _cf.releaseReservation(reservationId, reason: reason);
  }
}
