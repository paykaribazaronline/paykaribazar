import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/cart_service.dart';
import '../../../di/service_locator.dart';
import '../../../di/providers.dart';
import '../../../services/business_config_service.dart';
import '../../../models/user_model.dart';
import '../../../core/services/cloud_functions_client.dart';
import '../../../features/checkout/models/pricing_snapshot.dart';

export '../domain/cart_model.dart' show CartState;

final cartServiceProvider = Provider((ref) => getIt<CartService>());

final cartProvider = StateNotifierProvider<CartNotifier, CartState>((ref) {
  final service = ref.watch(cartServiceProvider);
  return CartNotifier(service);
});

/// UI-only optimistic total in taka (double). Kept for backwards
/// compatibility with existing widgets. New code MUST use
/// [serverPricingProvider] for any money decision — the server is the
/// source of truth for all totals, discounts, and fees.
@Deprecated('Use serverPricingProvider for any money decision. '
    'This value is a UI-only optimistic estimate and may differ from the '
    'server-computed snapshot.')
final cartSubtotalProvider = Provider<double>((ref) {
  return ref.watch(cartProvider).totalAmount;
});

/// Server-signed pricing snapshot for the current cart. Populated by
/// [CartNotifier.calculateServerTotals]. Always prefer this provider over
/// [cartSubtotalProvider] / [cartTotalProvider] / [cartDiscountProvider]
/// when making checkout-related decisions — those legacy providers remain
/// for optimistic UI display only.
final serverPricingProvider = StateProvider<PricingSnapshot?>((ref) => null);

final selectedAddressIdProvider = StateProvider<String?>((ref) => null);

/// DNA ENFORCED: Fetches selected address's location details for fee calculation
final userLocationDetailsProvider =
    FutureProvider<Map<String, dynamic>?>((ref) async {
  final userVal = ref.watch(actualUserDataProvider).value;
  if (userVal == null) return null;

  final user = UserModel.fromMap(userVal);
  if (user.addresses.isEmpty) return null;

  final selectedId = ref.watch(selectedAddressIdProvider);
  AddressModel? address;
  if (selectedId != null) {
    try {
      address = user.addresses.firstWhere((a) => a.id == selectedId);
    } catch (_) {}
  }
  address ??= user.defaultAddress;

  if (address == null) return null;

  final String? targetId = address.areaId;
  if (targetId != null && targetId.isNotEmpty) {
    final doc = await FirebaseFirestore.instance
        .collection(HubPaths.locations)
        .doc(targetId)
        .get();
    if (doc.exists) {
      final data = doc.data();
      if (data != null) {
        return {
          ...data,
          'baseCharge': (data['baseCharge'] ?? address.deliveryCharge).toDouble(),
        };
      }
    }
  }

  return {
    'baseCharge': address.deliveryCharge,
  };
});

/// Business Rules Provider (Reads from Firestore settings/business_rules)
final businessRulesProvider = StreamProvider<Map<String, dynamic>>((ref) {
  return FirebaseFirestore.instance
      .doc('settings/business_rules')
      .snapshots()
      .map((snap) => BusinessConfigService.mergeWithDefaults(snap.data()));
});

final cartMinimumOrderValueProvider = Provider<double>((ref) {
  final rules =
      ref.watch(businessRulesProvider).value ?? BusinessConfigService.defaults;
  return BusinessConfigService.getDoubleRule(
    'min_order_value',
    rules: rules,
  );
});

final cartShortfallProvider = Provider<double>((ref) {
  final subtotal = ref.watch(cartSubtotalProvider);
  final minimumOrder = ref.watch(cartMinimumOrderValueProvider);
  final remaining = minimumOrder - subtotal;
  return remaining > 0 ? remaining : 0;
});

final cartDeliveryFeeProvider = Provider<double>((ref) {
  final subtotal = ref.watch(cartSubtotalProvider);
  if (subtotal == 0) return 0;

  final rules =
      ref.watch(businessRulesProvider).value ?? BusinessConfigService.defaults;


  final locationAsync = ref.watch(userLocationDetailsProvider);
  final double defaultFee = BusinessConfigService.getDoubleRule(
    'delivery_fee_base',
    rules: rules,
  );

  return locationAsync.when(
    data: (locData) {
      if (locData == null) return defaultFee; 

      final double baseCharge = (locData['baseCharge'] ?? defaultFee).toDouble();
      final double maxCharge = (locData['maxCharge'] ?? 200.0).toDouble();
      final double extraWeightCharge =
          (locData['extraWeightCharge'] ?? 0.0).toDouble();
      final double maxBaseWeight = (locData['maxBaseWeight'] ?? 2.0).toDouble();

      // Calculate Weight Logic
      final items = ref.watch(cartProvider).items;
      double totalWeight = 0;
      for (var item in items) {
        // Assume default weight of 0.5kg if not specified
        totalWeight += (item.quantity * 0.5);
      }

      double finalFee = baseCharge;
      if (totalWeight > maxBaseWeight && extraWeightCharge > 0) {
        final double extraWeight = totalWeight - maxBaseWeight;
        finalFee += (extraWeight * extraWeightCharge);
      }

      return (finalFee.clamp(0.0, maxCharge) as num).toDouble();
    },
    loading: () => 0.0,
    error: (_, __) => defaultFee,
  );
});

final cartDiscountProvider = Provider<double>((ref) {
  final appliedCoupon = ref.watch(cartProvider).appliedCouponMap;
  if (appliedCoupon == null) return 0.0;

  final subtotal = ref.watch(cartSubtotalProvider);
  final type = appliedCoupon['type'] ?? 'fixed';
  final discountVal = (appliedCoupon['discount'] ?? 0.0).toDouble();

  if (type == 'percentage') {
    final maxDiscount = (appliedCoupon['maxDiscount'] ?? 999999.0).toDouble();
    final double calc = subtotal * (discountVal / 100);
    return calc > maxDiscount ? maxDiscount : calc;
  }
  return discountVal;
});

final cartPointsDiscountProvider = Provider<double>((ref) {
  return 0.0;
});

final cartTotalProvider = Provider<double>((ref) {
  final subtotal = ref.watch(cartSubtotalProvider);
  final delivery = ref.watch(cartDeliveryFeeProvider);
  final discount = ref.watch(cartDiscountProvider);
  final points = ref.watch(cartPointsDiscountProvider);
  return subtotal + delivery - discount - points;
});

class CartNotifier extends StateNotifier<CartState> {
  final CartService _service;

  CartNotifier(this._service) : super(CartState()) {
    _loadCart();
  }

  /// Calls the backend `calcOrder` callable to obtain a server-signed
  /// [PricingSnapshot] for the current cart contents. The result is exposed
  /// via [serverPricingProvider] — every checkout-related money decision
  /// (delivery fee, discount, grand total) MUST use the snapshot rather than
  /// the client-computed [cartSubtotalProvider].
  ///
  /// The caller should re-invoke this whenever:
  ///   - cart items change (add/remove/quantity),
  ///   - the selected address changes (delivery fee depends on it),
  ///   - the applied coupon changes,
  ///   - the snapshot's [PricingSnapshot.expiresAt] has passed (10-min TTL).
  Future<PricingSnapshot> calculateServerTotals({
    String? couponCode,
    String? businessId,
    String? addressId,
  }) async {
    final items = state.items
        .map((i) => <String, dynamic>{
              'productId': i.id,
              'quantity': i.quantity,
            })
        .toList(growable: false);

    final cf = cloudFunctionsClient;
    final snap = await cf.calcOrder(
      items: items,
      addressId: addressId,
      couponCode: couponCode,
      businessId: businessId,
    );
    // Stash into the StateProvider so other widgets can read it without
    // prop-drilling. We can't `ref.read()` from inside a non-Widget method
    // cleanly here; the caller (a Riverpod Consumer) is responsible for
    // writing the result back to [serverPricingProvider] — but for
    // convenience we still return it.
    return snap;
  }

  Future<void> _loadCart() async {
    state = state.copyWith(isLoading: true);
    final cloudItems = await _service.fetchSavedCart();
    if (cloudItems != null) {
      final items = cloudItems
          .map((m) => CartItem(
                id: m['id'],
                name: m['name'],
                imageUrl: m['imageUrl'],
                price: (m['price'] ?? 0.0).toDouble(),
                quantity: m['quantity'] ?? 1,
                unit: m['unit'] ?? 'pcs',
              ))
          .toList();
      state = state.copyWith(items: items, isLoading: false);
    } else {
      state = state.copyWith(isLoading: false);
    }
  }

  void _sync() {
    final list = state.items
        .map((i) => {
              'id': i.id,
              'name': i.name,
              'imageUrl': i.imageUrl,
              'price': i.price,
              'quantity': i.quantity,
              'unit': i.unit,
            })
        .toList();
    _service.syncCartToCloud(list);
  }

  void addItem(CartItem item) {
    final index = state.items.indexWhere((i) => i.id == item.id);
    if (index != -1) {
      final updatedItems = [...state.items];
      updatedItems[index].quantity += 1;
      state = state.copyWith(items: updatedItems);
    } else {
      state = state.copyWith(items: [...state.items, item]);
    }
    _sync();
  }

  void removeItem(String id) {
    final index = state.items.indexWhere((i) => i.id == id);
    if (index != -1) {
      final updatedItems = [...state.items];
      if (updatedItems[index].quantity > 1) {
        updatedItems[index].quantity -= 1;
        state = state.copyWith(items: updatedItems);
      } else {
        state = state.copyWith(
            items: state.items.where((i) => i.id != id).toList());
      }
      _sync();
    }
  }

  /// Semantic alias: decreases item quantity by 1, or removes if qty is 1.
  void decreaseQuantity(String id) => removeItem(id);

  void updateQuantity(String id, int quantity) {
    final index = state.items.indexWhere((i) => i.id == id);
    if (index != -1 && quantity > 0) {
      final updatedItems = [...state.items];
      updatedItems[index].quantity = quantity;
      state = state.copyWith(items: updatedItems);
      _sync();
    }
  }

  Future<String> applyCouponMap(
      Map<String, dynamic>? coupon, Map<String, dynamic>? userData) async {
    if (coupon == null) {
      state = state.copyWith();
      return 'REMOVED';
    }

    final minOrder = (coupon['minOrder'] ?? 0.0).toDouble();
    if (state.totalAmount < minOrder) {
      return 'Min order ৳$minOrder required';
    }

    state = state.copyWith(appliedCouponMap: coupon);
    return 'SUCCESS';
  }

  void clearCart() {
    state = state.copyWith(items: []);
    _service.clearCloudCart();
  }
}
