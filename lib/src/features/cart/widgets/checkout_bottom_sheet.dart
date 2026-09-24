import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:paykari_bazar/src/di/providers.dart'; // MASTER HUB IMPORT
import 'package:paykari_bazar/src/core/services/security_initializer.dart';
import '../../../models/user_model.dart';
import '../../../utils/styles.dart';
import '../../../utils/app_strings.dart';
import '../../profile/widgets/address_form_sheet.dart';
import '../../commerce/providers/cart_provider.dart';

class CheckoutBottomSheet extends ConsumerStatefulWidget {
  const CheckoutBottomSheet({super.key});
  @override
  ConsumerState<CheckoutBottomSheet> createState() =>
      _CheckoutBottomSheetState();
}

class _CheckoutBottomSheetState extends ConsumerState<CheckoutBottomSheet> {
  bool _loading = false;
  final _phoneCtrl = TextEditingController();
  String? _selectedAddressId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final userValue = ref.read(currentUserDataProvider).value;
      if (userValue != null) {
        _phoneCtrl.text = (userValue['phone'] ?? '').toString();
        final userModel = UserModel.fromMap(userValue);
        if (userModel.addresses.isNotEmpty) {
          final initialAddr =
              userModel.defaultAddress ?? userModel.addresses.first;
          setState(() {
            _selectedAddressId = initialAddr.id;
          });
          ref.read(selectedAddressIdProvider.notifier).state = initialAddr.id;
        }
      }
    });
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  String _t(String k) =>
      AppStrings.get(k, ref.watch(languageProvider).languageCode);



  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userValue = ref.watch(currentUserDataProvider).value;
    final userModel = userValue != null ? UserModel.fromMap(userValue) : null;
    final cartNotifier = ref.watch(cartProvider.notifier);

    final subtotal = ref.watch(cartSubtotalProvider);
    final deliveryFee = ref.watch(cartDeliveryFeeProvider);
    final discount = ref.watch(cartDiscountProvider);
    final pointsDiscount = ref.watch(cartPointsDiscountProvider);
    final total = ref.watch(cartTotalProvider);
    final minOrderValue = ref.watch(cartMinimumOrderValueProvider);
    final orderShortfall = ref.watch(cartShortfallProvider);
    final isBelowMinimumOrder = orderShortfall > 0;

    final isAddressMissing = userModel == null || userModel.addresses.isEmpty;

    AddressModel? selectedAddress;
    
    // Helper to find address
    AddressModel? getAddress(String? id) {
      if (userModel == null || id == null) return null;
      try {
        return userModel.addresses.firstWhere((a) => a.id == id);
      } catch (_) {
        return userModel.addresses.isNotEmpty ? userModel.addresses.first : null;
      }
    }

    selectedAddress = getAddress(_selectedAddressId);

    // UI logic for showing address details
    String getAddressSummary(AddressModel addr) {
      final parts = [
        addr.area.isNotEmpty ? addr.area : null,
        addr.station.isNotEmpty ? addr.station : null,
        addr.upazila.isNotEmpty ? addr.upazila : null,
      ].whereType<String>().toList();
      return parts.take(2).join(', ');
    }

    if (userModel != null && _selectedAddressId != null) {
      try {
        selectedAddress =
            userModel.addresses.firstWhere((a) => a.id == _selectedAddressId);
      } catch (_) {
        selectedAddress =
            userModel.addresses.isNotEmpty ? userModel.addresses.first : null;
      }
    }

    return Container(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          left: 24,
          right: 24,
          top: 16),
      decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(10))),
        const SizedBox(height: 20),
        if (isAddressMissing) ...[
          _buildAddressCompletionPrompt(),
        ] else ...[
          // Visual Address Selection Card (Smarter UI)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? Colors.white10 : Colors.grey[100],
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: AppStyles.primaryColor.withValues(alpha: 0.1),
                  child: const Icon(Icons.location_on, color: AppStyles.primaryColor),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(selectedAddress?.name ?? 'Select Address',
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                      if (selectedAddress != null)
                        Text(getAddressSummary(selectedAddress),
                            style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => _showAddressPicker(userModel, userValue),
                  child: Text(_t('change'), style: const TextStyle(fontWeight: FontWeight.bold)),
                )
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (selectedAddress != null) ...[
                TextButton.icon(
                  icon: const Icon(Icons.add_location_alt_outlined, size: 16),
                  label: Text(
                    ref.watch(languageProvider).languageCode == 'bn' ? 'নতুন ঠিকানা' : 'New Address',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  onPressed: () => _addNewAddress(userValue),
                ),
                const VerticalDivider(),
                TextButton.icon(
                  icon: const Icon(Icons.edit_note, size: 16),
                  label: Text(
                    ref.watch(languageProvider).languageCode == 'bn' ? 'এডিট' : 'Edit',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  onPressed: () => _editAddress(selectedAddress!, userValue),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: AppStyles.inputDecoration(_t('contactPhone'), isDark,
                  prefix: const Icon(Icons.phone_iphone_rounded,
                      size: 18, color: AppStyles.primaryColor))),
          const SizedBox(height: 24),
          _summary(
              subtotal, deliveryFee, isDark, discount, pointsDiscount, total, minOrderValue, orderShortfall),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: (selectedAddress == null || _loading || isBelowMinimumOrder)
                ? null
                : () => _placeOrder(cartNotifier, ref.read(cartProvider),
                    userModel, selectedAddress!),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppStyles.primaryColor,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 60),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18)),
                elevation: 8,
                shadowColor: AppStyles.primaryColor.withValues(alpha: 0.4)),
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : Text(_t('confirmOrder').toUpperCase(),
                    style: const TextStyle(
                        fontWeight: FontWeight.w900, letterSpacing: 1)),
          ),
          const SizedBox(height: 20),
        ],
      ]),
    );
  }

  void _showAddressPicker(UserModel model, Map<String, dynamic>? userValue) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: ListView(
          shrinkWrap: true,
          children: [
            ...model.addresses.map((addr) => ListTile(
              leading: const Icon(Icons.location_on_outlined),
              title: Text(addr.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(addr.fullAddress, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: _selectedAddressId == addr.id ? const Icon(Icons.check_circle, color: AppStyles.primaryColor) : null,
              onTap: () {
                setState(() => _selectedAddressId = addr.id);
                ref.read(selectedAddressIdProvider.notifier).state = addr.id;
                Navigator.pop(context);
              },
            )),
            ListTile(
              leading: const Icon(Icons.add_circle_outline, color: AppStyles.primaryColor),
              title: const Text('Add New Address', style: TextStyle(color: AppStyles.primaryColor, fontWeight: FontWeight.bold)),
              onTap: () {
                Navigator.pop(context);
                _addNewAddress(userValue);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _addNewAddress(Map<String, dynamic>? userValue) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => AddressFormSheet(userData: userValue),
    ).then((_) => _refreshAddressSelection());
  }

  void _editAddress(AddressModel addr, Map<String, dynamic>? userValue) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => AddressFormSheet(
        userData: {
          ...userValue ?? {},
          'addressId': addr.id,
          'districtId': addr.district,
          'upazilaId': addr.upazila,
          'stationId': addr.station,
          'areaId': addr.areaId,
          'details': addr.detailedAddress,
          'nameTag': addr.name,
          'charge': addr.deliveryCharge,
        },
      ),
    ).then((_) => _refreshAddressSelection());
  }

  void _refreshAddressSelection() {
    final updatedUser = ref.read(currentUserDataProvider).value;
    if (updatedUser != null) {
      final updatedModel = UserModel.fromMap(updatedUser);
      if (updatedModel.addresses.isNotEmpty) {
        final latest = updatedModel.addresses.last;
        setState(() => _selectedAddressId = latest.id);
        ref.read(selectedAddressIdProvider.notifier).state = latest.id;
      }
    }
  }

  Widget _buildAddressCompletionPrompt() {
    final userValue = ref.watch(currentUserDataProvider).value;
    final lang = ref.watch(languageProvider).languageCode;
    return Column(children: [
      const Icon(Icons.home_work_outlined, size: 60, color: Colors.orange),
      const SizedBox(height: 16),
      const Text('Add a Delivery Address',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
      const SizedBox(height: 8),
      const Text(
          'Please add at least one address (Home or Office) to proceed with your order.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey, fontSize: 13)),
      const SizedBox(height: 24),
      ElevatedButton(
          onPressed: () {
            showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (context) => AddressFormSheet(userData: userValue),
            ).then((_) {
              final updatedUser = ref.read(currentUserDataProvider).value;
              if (updatedUser != null) {
                final updatedModel = UserModel.fromMap(updatedUser);
                if (updatedModel.addresses.isNotEmpty) {
                  final newAddr = updatedModel.addresses.last;
                  setState(() {
                    _selectedAddressId = newAddr.id;
                  });
                  ref.read(selectedAddressIdProvider.notifier).state = newAddr.id;
                }
              }
            });
          },
          style: ElevatedButton.styleFrom(
              backgroundColor: AppStyles.primaryColor,
              minimumSize: const Size(double.infinity, 55),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15))),
          child: Text(lang == 'bn' ? 'নতুন ঠিকানা যোগ করুন' : 'ADD ADDRESS',
              style: const TextStyle(fontWeight: FontWeight.bold))),
    ]);
  }

  Widget _summary(double sub, double del, bool d, double discount,
      double ptsDiscount, double total, double minOrderValue, double orderShortfall) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: AppStyles.primaryColor.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppStyles.primaryColor.withValues(alpha: 0.1))),
      child: Column(children: [
        _row(_t('subtotal'), '৳${sub.toInt()}'),
        if (discount > 0)
          _row('Coupon Discount', '- ৳${discount.toInt()}', c: Colors.green),
        if (ptsDiscount > 0)
          _row('Points Discount', '- ৳${ptsDiscount.toInt()}',
              c: Colors.orange),
        _row(_t('deliveryFee'), '+ ৳${del.toInt()}'),
        if (orderShortfall > 0)
          _row(
            ref.watch(languageProvider).languageCode == 'bn' ? 'ন্যূনতম অর্ডারের ঘাটতি' : 'Minimum Order Shortfall',
            'Need ৳${orderShortfall.toInt()} more',
            c: Colors.orange,
          ),
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 8), child: Divider()),
        _row(_t('totalPayable'), '৳${total.toInt()}', b: true),
        if (orderShortfall > 0) ...[
          const SizedBox(height: 10),
          Text(
            ref.watch(languageProvider).languageCode == 'bn'
                ? 'ন্যূনতম অর্ডার ৳${minOrderValue.toInt()}। অর্ডার সম্পন্ন করতে আরও কিছু পণ্য যোগ করুন।'
                : 'Minimum order is ৳${minOrderValue.toInt()}. Add a bit more to place this order.',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.orange,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ]),
    );
  }

  Widget _row(String l, String v, {bool b = false, Color? c}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(l,
            style: TextStyle(
                fontWeight: b ? FontWeight.w900 : FontWeight.bold,
                fontSize: b ? 16 : 13)),
        Text(v,
            style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: b ? 18 : 14,
                color: c ?? (b ? AppStyles.primaryColor : null)))
      ]));

  Future<void> _placeOrder(
      CartNotifier c, CartState state, UserModel u, AddressModel addr) async {
    setState(() => _loading = true);

    final double subtotal = ref.read(cartSubtotalProvider);
    final double deliveryFee = ref.read(cartDeliveryFeeProvider);
    final double discount = ref.read(cartDiscountProvider);
    final double pointsDiscount = ref.read(cartPointsDiscountProvider);
    final double finalTotal = ref.read(cartTotalProvider);
    final double orderShortfall = ref.read(cartShortfallProvider);

    if (orderShortfall > 0) {
      if (mounted) {
        final isBn = ref.read(languageProvider).languageCode == 'bn';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isBn 
                ? 'ন্যূনতম অর্ডার সম্পূর্ণ করতে আরও ৳${orderShortfall.toInt()} মূল্যের পণ্য যোগ করুন।' 
                : 'Add ৳${orderShortfall.toInt()} more to meet the minimum order.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      setState(() => _loading = false);
      return;
    }

    try {
      // TODO(audit): this entire `_placeOrder` body is the LEGACY client-side
      // flow. It bypasses the secure backend (OrderService.placeOrder /
      // CheckoutService.checkout) by:
      //   1. Computing totals + discounts client-side (lines 405-409).
      //   2. Decrementing product stock directly via a Firestore transaction
      //      (lines 459-474) — the new `firestore.rules` block this with
      //      `allow update: if false` on `products/{id}.stock`, so every
      //      real order will throw PERMISSION_DENIED here in production.
      //   3. Writing the order doc directly to Firestore
      //      (`firestoreServiceProvider.placeOrder`, line 507) — also
      //      blocked by the new rules (`allow create: if false` on
      //      `orders/{orderId}`).
      //   4. Signing an "API request" client-side via APISecurityService
      //      (lines 477-505) — purely cosmetic, the signature is never
      //      verified server-side.
      //
      // The replacement flow is:
      //   ref.read(checkoutProvider.notifier).startCheckout(
      //     CheckoutRequest(
      //       items: state.items
      //           .map((i) => CartItemRequest(
      //                 productId: i.id, quantity: i.quantity))
      //           .toList(growable: false),
      //       addressId: addr.id,
      //       paymentMethod: <selected from PaymentMethodSelector>,
      //       couponCode: state.appliedCouponMap?['code'],
      //       note: null,
      //     ),
      //   );
      // and then observe `checkoutProvider` state transitions
      // (CheckoutRedirecting -> CheckoutVerifying -> CheckoutSuccess).
      // Migration is deferred because it requires:
      //   - adding the PaymentMethodSelector UI to this sheet,
      //   - threading the server-computed PricingSnapshot into the
      //     summary display,
      //   - and handling the gateway-redirect + verify UI states.
      // Until the migration lands, this sheet will fail at runtime against
      // the production backend — use the new checkout flow via
      // `CheckoutBottomSheetV2` (planned) instead.

      // ⭐ SECURITY: Step 1 - Biometric Verification for high-value operations
      final secureAuth = SecurityInitializer.secureAuth;
      final isAuthenticated = await secureAuth.authenticateForSensitiveOperation(
        localizedReason: 'Confirm payment of ৳${finalTotal.toInt()}',
      );

      if (!isAuthenticated) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Verification failed. Order not placed.')),
          );
        }
        return;
      }

      final items = state.items
          .map((i) => {
                'productId': i.id,
                'productName': i.name,
                'price': i.price,
                'quantity': i.quantity,
                'imageUrl': i.imageUrl
              })
          .toList();

       final insufficient = items.where((it) => (it['quantity'] as int) > 999).toList();
       if (insufficient.isNotEmpty) {
         throw Exception('Some items exceed available stock limit.');
       }

       await FirebaseFirestore.instance.runTransaction((tx) async {
         for (final it in items) {
           final productRef = FirebaseFirestore.instance.collection(HubPaths.products).doc(it['productId'] as String);
           final snap = await tx.get(productRef);
           if (!snap.exists) {
             throw Exception('Product "${it['productName']}" no longer exists.');
           }
           final data = snap.data() as Map<String, dynamic>;
           final currentStock = (data['stock'] ?? 0) as int;
           final qty = it['quantity'] as int;
           if (currentStock < qty) {
             throw Exception('Insufficient stock for "${it['productName']}". Available: $currentStock');
           }
           tx.update(productRef, {'stock': FieldValue.increment(-qty)});
         }
       });

       // ⭐ SECURITY: Step 2 - Sign API Request (Simulation) and Encrypt ID
       final apiSecurity = SecurityInitializer.apiSecurity;
       final encryption = SecurityInitializer.encryption;

      final orderData = {
        'customerUid': u.id,
        'customerName': u.name,
        'customerPhone': _phoneCtrl.text.trim(),
        'deliveryAddress': addr.fullAddress,
        'deliveryArea': addr.area,
        'deliveryAreaId': addr.areaId,
        'subtotal': subtotal,
        'deliveryFee': deliveryFee,
        'discount': discount,
        'pointsDiscount': pointsDiscount,
        'totalAmount': finalTotal,
        'status': 'Pending',
        'items': items,
        'isEmergency': false,
        'orderType': 'regular',
        'createdAt': FieldValue.serverTimestamp(),
        'security_token': encryption.encrypt(u.id), // Encrypt sensitive field
      };

      // Get secure headers for the "API call"
      final headers = apiSecurity.getSecureHeaders(
        endpoint: '/api/orders/place',
        body: orderData.toString(),
      );
      debugPrint('✅ Secure Headers generated: ${headers['X-Signature']}');

      await ref.read(firestoreServiceProvider).placeOrder(orderData);

      await ref
          .read(loyaltyServiceProvider)
          .handleReferralPurchase(u.id, subtotal);

      c.clearCart();

      if (mounted) {
        Navigator.pop(context);
        context.push('/orders');
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Order placed securely! ✅'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
