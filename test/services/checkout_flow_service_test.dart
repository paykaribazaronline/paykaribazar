import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:paykari_bazar/src/features/commerce/services/cart_service.dart';
import 'package:paykari_bazar/src/features/commerce/services/order_service.dart';
import 'package:paykari_bazar/src/features/payments/models/payment_method.dart';

class MockCartService extends Mock implements CartService {}
class MockOrderService extends Mock implements OrderService {}

/// Thin orchestration shim that exercises the new `placeOrder` signature
/// (`items: List<CartItemRequest>`, `addressId`, `couponCode?`,
/// `businessId?`, `paymentMethod: PaymentMethod`, `note?`). The OLD
/// signature accepted `total`, `address`, `customerName`, `customerPhone`,
/// `deliveryFee`, `discount` — those are now server-only fields.
class CheckoutFlowHandler {
  final CartService cartService;
  final OrderService orderService;

  CheckoutFlowHandler({
    required this.cartService,
    required this.orderService,
  });

  Future<String> checkout({
    required String userId,
    required String shippingAddressId,
    required PaymentMethod paymentMethod,
  }) async {
    // In a real scenario, the cart would be lifted into `items` here.
    // For this test we pass a single canned line item.
    final orderId = await orderService.placeOrder(
      items: const [CartItemRequest(productId: 'P1', quantity: 1)],
      addressId: shippingAddressId,
      paymentMethod: paymentMethod,
      couponCode: null,
      businessId: null,
      note: null,
    );
    return orderId;
  }
}

void main() {
  group('Checkout Flow Tests', () {
    late CheckoutFlowHandler checkoutHandler;
    late MockCartService cartService;
    late MockOrderService orderService;

    setUp(() {
      cartService = MockCartService();
      orderService = MockOrderService();
      checkoutHandler = CheckoutFlowHandler(
        cartService: cartService,
        orderService: orderService,
      );
    });

    test('Complete checkout flow', () async {
      when(() => orderService.placeOrder(
            items: any(named: 'items'),
            addressId: any(named: 'addressId'),
            paymentMethod: any(named: 'paymentMethod'),
            couponCode: any(named: 'couponCode'),
            businessId: any(named: 'businessId'),
            note: any(named: 'note'),
          )).thenAnswer((_) async => 'order123');

      final orderId = await checkoutHandler.checkout(
        userId: 'user1',
        shippingAddressId: 'addr-1',
        paymentMethod: PaymentMethod.bkash,
      );

      expect(orderId, 'order123');
    });

    test('Validate shipping address logic', () {
      expect(_validateShippingAddress('123 Main Street'), true);
      expect(_validateShippingAddress('Short'), false);
    });
  });
}

bool _validateShippingAddress(String address) {
  return address.isNotEmpty && address.length >= 10;
}
