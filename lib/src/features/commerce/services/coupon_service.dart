import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/constants/paths.dart';

class CouponService {
  final FirebaseFirestore _db;

  CouponService({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;

  Future<void> initialize() async {
    // Initialization logic if needed
  }

  /// Validates coupon code and returns discount info.
  ///
  /// NOTE: This is a READ-ONLY PREVIEW. Authoritative coupon redemption
  /// happens inside `calcOrder` server-side (transactional, with
  /// double-redemption protection). The result of this method should
  /// never be trusted for the final order total — it exists only to show
  /// the user an optimistic "you will save ৳X" preview before they tap
  /// "Place Order".
  @Deprecated('Use CloudFunctionsClient.calcOrder with couponCode — the '
      'backend validates transactionally. This client-side preview does not '
      'enforce atomicity or double-redemption protection.')
  Future<Map<String, dynamic>?> validateCoupon({
    required String couponCode,
    required double cartTotal,
    required String userId,
  }) async {
    try {
      final doc = await _db
          .collection(HubPaths.coupons)
          .doc(couponCode.toUpperCase())
          .get();

      if (!doc.exists) {
        return null; // Invalid coupon
      }

      final couponData = doc.data()!;
      final bool isActive = couponData['isActive'] ?? false;
      final DateTime expiryDate = (couponData['expiryDate'] as Timestamp).toDate();
      final double minOrderValue = couponData['minOrderValue'] ?? 0.0;
      final int maxUses = couponData['maxUses'] ?? -1;
      final int currentUses = couponData['currentUses'] ?? 0;

      // Validations
      if (!isActive) return null; // Coupon inactive
      if (DateTime.now().isAfter(expiryDate)) return null; // Expired
      if (cartTotal < minOrderValue) return null; // Minimum order not met
      if (maxUses != -1 && currentUses >= maxUses) return null; // Max uses exceeded

      // Check if user already used this coupon
      final userCoupons = (couponData['usedBy'] as List<dynamic>?) ?? [];
      if (userCoupons.contains(userId)) {
        return null; // User already used this coupon
      }

      return {
        'code': couponCode.toUpperCase(),
        'discountType': couponData['discountType'], // 'percentage' or 'fixed'
        'discountValue': couponData['discountValue'],
        'maxDiscount': couponData['maxDiscount'], // Max discount cap
        'isValid': true,
      };
    } catch (e) {
      return null;
    }
  }

  /// Calculates discount amount based on coupon type.
  ///
  /// NOTE: This method is retained for UI preview purposes only. The
  /// backend's `calcOrder` callable is the source of truth for the
  /// final discount applied to an order (see
  /// `functions/src/pricing/calcOrder.ts`). This client-side mirror exists
  /// so the cart screen can show an optimistic estimate before the user
  /// taps checkout — it uses the same math but does NOT enforce atomicity,
  /// MOQ, or double-redemption.
  double calculateDiscount({
    required String discountType,
    required double discountValue,
    required double cartTotal,
    double? maxDiscount,
  }) {
    double discount = 0.0;

    if (discountType == 'percentage') {
      discount = (cartTotal * discountValue) / 100;
      if (maxDiscount != null && discount > maxDiscount) {
        discount = maxDiscount;
      }
    } else if (discountType == 'fixed') {
      discount = discountValue;
    }

    return discount > cartTotal ? cartTotal : discount;
  }

  /// Applies coupon to order
  Future<void> applyCouponToOrder({
    required String orderId,
    required String couponCode,
    required String userId,
    required double discountAmount,
  }) async {
    try {
      // Update coupon usage
      await _db.collection(HubPaths.coupons).doc(couponCode).update({
        'currentUses': FieldValue.increment(1),
        'usedBy': FieldValue.arrayUnion([userId]),
        'lastUsedAt': FieldValue.serverTimestamp(),
      });

      // Store coupon in order
      await _db.collection(HubPaths.orders).doc(orderId).update({
        'appliedCoupon': couponCode,
        'couponDiscount': discountAmount,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      rethrow;
    }
  }

  /// Gets all active coupons for user
  Stream<List<Map<String, dynamic>>> getActiveCoupons(String userId) {
    final now = DateTime.now();
    return _db
        .collection(HubPaths.coupons)
        .where('isActive', isEqualTo: true)
        .where('expiryDate', isGreaterThan: Timestamp.fromDate(now))
        .snapshots()
        .map((snap) =>
            snap.docs.map((doc) => {'code': doc.id, ...doc.data()}).toList());
  }

  /// Revokes coupon application
  Future<void> revokeCoupon({
    required String orderId,
    required String couponCode,
    required String userId,
  }) async {
    try {
      await _db.collection(HubPaths.coupons).doc(couponCode).update({
        'currentUses': FieldValue.increment(-1),
        'usedBy': FieldValue.arrayRemove([userId]),
      });

      await _db.collection(HubPaths.orders).doc(orderId).update({
        'appliedCoupon': null,
        'couponDiscount': 0.0,
      });
    } catch (e) {
      rethrow;
    }
  }
}
