import 'package:cloud_firestore/cloud_firestore.dart' hide Order;
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/constants/paths.dart';
import '../../../core/services/cloud_functions_client.dart';
import '../../../features/payments/models/payment_method.dart';
import '../../../models/order_model.dart';

/// DTO used by the new `placeOrder` method. The cart-line shape matches the
/// `items[]` field the backend `calcOrder` callable expects.
class CartItemRequest {
  final String productId;
  final int quantity;
  final String? variantId;

  const CartItemRequest({
    required this.productId,
    required this.quantity,
    this.variantId,
  });

  Map<String, dynamic> toJson() => {
        'productId': productId,
        'quantity': quantity,
        if (variantId != null) 'variantId': variantId,
      };
}

/// Production order service. Order creation now flows through the secure
/// `calcOrder` → `reserveStock` → `createOrder` callables (Task ID 9
/// backend) and the client NEVER writes totals, items, or stock directly
/// to Firestore.
///
/// The legacy [createOrder] (direct Firestore write) is retained behind a
/// `@Deprecated` annotation so existing callers compile, but the new
/// backend-enforced `firestore.rules` (Task ID 7-8) reject the write with
/// `allow create: if false` on `orders/{orderId}` — so any caller that
/// still uses it will receive a clear permission-denied error.
class OrderService {
  OrderService({
    CloudFunctionsClient? cf,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _cf = cf ?? cloudFunctionsClient,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final CloudFunctionsClient _cf;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  /// The ONLY secure order-creation path. The caller supplies cart items +
  /// address + payment method (+ optional coupon / businessId). The
  /// method returns the new orderId after the backend has:
  ///   1. Computed prices server-side (`calcOrder`)
  ///   2. Atomically reserved inventory (`reserveStock`)
  ///   3. Written the order doc with server-computed totals (`createOrder`)
  ///
  /// The returned orderId is then passed to a payment-initiation callable
  /// (e.g. `bkashCreatePayment`) to obtain the gateway URL. The
  /// [CheckoutService] in `features/checkout/` wraps the entire flow into
  /// one call — prefer that for new UIs.
  Future<String> placeOrder({
    required List<CartItemRequest> items,
    required String addressId,
    String? couponCode,
    String? businessId,
    required PaymentMethod paymentMethod,
    String? note,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('User must be authenticated to place an order.');
    }

    final snapshot = await _cf.calcOrder(
      items: items.map((i) => i.toJson()).toList(growable: false),
      addressId: addressId,
      couponCode: couponCode,
      businessId: businessId,
    );
    final reservation = await _cf.reserveStock(snapshot);
    final orderId = await _cf.createOrder(
      snap: snapshot,
      reservationId: reservation.reservationId,
      addressId: addressId,
      paymentMethod: paymentMethod,
      note: note,
    );
    return orderId;
  }

  /// Stream of customer orders (read-only — the new rules allow owner +
  /// staff reads). Unchanged from the original implementation.
  Stream<List<Map<String, dynamic>>> getCustomerOrders(String uid) {
    return _firestore
        .collection(HubPaths.orders)
        .where('customerUid', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) =>
            snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
  }

  /// Type-safe variant of [getCustomerOrders] (unchanged).
  Stream<List<Order>> getCustomerOrdersAsModels(String uid) {
    return _firestore
        .collection(HubPaths.orders)
        .where('customerUid', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) => Order.fromMap({'id': doc.id, ...doc.data()}))
            .toList());
  }

  /// Customer-side status updates are restricted by the new rules to
  /// self-cancellation only (`status == 'cancelled'`, fields `['status',
  /// 'updatedAt']` only). Any other status requires staff/admin role,
  /// which the client cannot assert — so we route through the backend
  /// `cancelOrder` callable for `cancelled` and throw for everything else.
  Future<void> updateOrderStatus(String orderId, String status) async {
    if (status == 'cancelled') {
      await _cf.cancelOrder(orderId, reason: 'customer_cancelled');
      return;
    }
    throw UnsupportedError(
      'Only staff may set status=$status. Use a staff-credentialled callable.',
    );
  }

  /// Cancel an order. Delegates to the backend `cancelOrder` callable
  /// which atomically releases the reservation (if unpaid) or creates a
  /// refund request (if paid).
  Future<void> cancelOrder(String orderId, {String? reason}) {
    return _cf.cancelOrder(orderId,
        reason: reason ?? 'customer_cancelled');
  }

  /// Fetch a single order by ID. Read is allowed by `firestore.rules` for
  /// the order owner + staff.
  Future<Order?> getOrderById(String orderId) async {
    try {
      final doc =
          await _firestore.collection(HubPaths.orders).doc(orderId).get();
      if (doc.exists) {
        return Order.fromMap({'id': doc.id, ...doc.data()!});
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Pending orders (admin/rider view). Reads are allowed by `firestore.rules`
  /// for staff + rider roles only.
  Stream<List<Order>> getPendingOrders() {
    return _firestore
        .collection(HubPaths.orders)
        .where('status', isEqualTo: OrderStatus.pending.toDisplayString())
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) => Order.fromMap({'id': doc.id, ...doc.data()}))
            .toList());
  }

  /// Rider assignment is a staff-only operation. The new rules forbid the
  /// client from writing `riderUid` — callers must use a staff-credentialled
  /// callable (TBD: `assignRider` in a follow-up patch). Until then, this
  /// method throws.
  Future<void> assignToRider(String orderId, String riderUid) async {
    throw UnsupportedError(
      'assignToRider is now a staff-only operation. Use the assignRider '
      'callable (planned in a follow-up patch).',
    );
  }

  // ----------------------------- legacy ----------------------------------

  /// Direct Firestore write of an [Order] model. Kept for source
  /// compatibility only — the new `firestore.rules` block this path with
  /// `allow create: if false` on `orders/{orderId}`. Callers should
  /// migrate to [placeOrder].
  @Deprecated('Use placeOrder(). All order creation now goes through the '
      'createOrder callable — direct Firestore writes are blocked by the '
      'new firestore.rules (Task ID 7-8).')
  Future<String> createOrder(Order order) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('User not logged in');

    final orderData = order.toMap();
    orderData.remove('id');
    orderData['createdAt'] = FieldValue.serverTimestamp();
    orderData['updatedAt'] = FieldValue.serverTimestamp();

    final docRef =
        await _firestore.collection(HubPaths.orders).add(orderData);
    await docRef.update({'id': docRef.id});
    return docRef.id;
  }

  /// Legacy `updateOrder(Order)` — the new rules block writes from the
  /// client. Kept for source compatibility only.
  @Deprecated('Direct Firestore order updates are blocked by the new '
      'firestore.rules. Use updateOrderStatus() for customer self-cancellation '
      'or the staff callables for staff operations.')
  Future<void> updateOrder(Order order) async {
    await _firestore.collection(HubPaths.orders).doc(order.id).update({
      ...order.toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Legacy direct-write cancellation. Replaced by [cancelOrder] above.
  @Deprecated('Use cancelOrder(orderId, reason) — the new rules block direct '
      'status writes from the client.')
  Future<void> cancelOrderLegacy(String orderId, String? reason) async {
    await _firestore.collection(HubPaths.orders).doc(orderId).update({
      'status': OrderStatus.cancelled.toDisplayString(),
      'cancellationReason': reason,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
}
