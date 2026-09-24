import 'package:cloud_firestore/cloud_firestore.dart' hide Order;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:paykari_bazar/src/core/services/cloud_functions_client.dart';
import 'package:paykari_bazar/src/features/commerce/services/order_service.dart';
import 'package:paykari_bazar/src/features/payments/models/payment_method.dart';
import 'package:paykari_bazar/src/models/order_model.dart' as app_models;

class MockOrderService extends Mock implements OrderService {}
class FakeOrder extends Fake implements app_models.Order {}

// Lightweight mocks for the OrderService constructor dependencies — used by
// the real-OrderService smoke test below. The Mock* types only need to
// implement the surface that OrderService touches (currentUser for the
// unauthenticated guard).
class _MockFirebaseAuth extends Mock implements FirebaseAuth {}
class _MockCloudFunctionsClient extends Mock implements CloudFunctionsClient {}
class _MockFirebaseFirestore extends Mock implements FirebaseFirestore {}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeOrder());
  });

  group('OrderService Tests', () {
    late MockOrderService orderService;

    setUp(() {
      orderService = MockOrderService();
    });

    // ---------------------------------------------------------------------------
    // placeOrder — the OLD signature (total / address / customerName /
    // customerPhone / deliveryFee / discount) was replaced in the
    // production-hardening patch with a backend-enforced signature that
    // accepts `items: List<CartItemRequest>`, `addressId`, `couponCode?`,
    // `businessId?`, `paymentMethod: PaymentMethod`, `note?`. The stubbed
    // MockOrderService test below uses the new signature. See the
    // `OrderService.placeOrder (real-instance smoke tests)` group for an
    // integration-style test that exercises the real code path (and proves
    // the unauthenticated guard still throws StateError).
    // ---------------------------------------------------------------------------
    test('placeOrder returns orderId (mocked with new signature)', () async {
      when(() => orderService.placeOrder(
            items: any(named: 'items'),
            addressId: any(named: 'addressId'),
            paymentMethod: any(named: 'paymentMethod'),
            couponCode: any(named: 'couponCode'),
            businessId: any(named: 'businessId'),
            note: any(named: 'note'),
          )).thenAnswer((_) async => 'order456');

      final result = await orderService.placeOrder(
        items: const [CartItemRequest(productId: 'P1', quantity: 2)],
        addressId: 'addr-1',
        paymentMethod: PaymentMethod.bkash,
        couponCode: null,
        businessId: null,
        note: null,
      );

      expect(result, 'order456');
    });

    test('Get customer orders stream', () async {
      final orders = [
        {
          'id': 'order1',
          'customerUid': 'user1',
          'customerName': 'Test',
          'customerPhone': '01700000000',
          'items': <Map<String, dynamic>>[],
          'subtotal': 100.0,
          'deliveryFee': 10.0,
          'discount': 0.0,
          'total': 110.0,
          'address': 'Addr',
          'paymentMethod': 'COD',
        },
      ];
      when(() => orderService.getCustomerOrders('user1'))
          .thenAnswer((_) => Stream.value(orders));

      final stream = orderService.getCustomerOrders('user1');
      final result = await stream.first;
      expect(result.length, 1);
      expect(result.first['id'], 'order1');
    });

    test('Create order from model', () async {
      final order = app_models.Order(
        id: 'order-model-1',
        customerUid: 'user1',
        customerName: 'Test',
        customerPhone: '01700000000',
        items: [],
        subtotal: 100.0,
        deliveryFee: 10.0,
        discount: 0.0,
        total: 110.0,
        address: 'Addr',
        paymentMethod: 'COD',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      when(() => orderService.createOrder(any<app_models.Order>()))
          .thenAnswer((_) async => 'order-model-1');

      final result = await orderService.createOrder(order);
      expect(result, 'order-model-1');
    });

    test('Update order', () async {
      final order = app_models.Order(
        id: 'order-update-1',
        customerUid: 'user1',
        customerName: 'Test',
        customerPhone: '01700000000',
        items: [],
        subtotal: 100.0,
        deliveryFee: 10.0,
        discount: 0.0,
        total: 110.0,
        address: 'Addr',
        paymentMethod: 'COD',
        status: app_models.OrderStatus.confirmed,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      when(() => orderService.updateOrder(any<app_models.Order>()))
          .thenAnswer((_) async => Future.value());

      await orderService.updateOrder(order);
      verify(() => orderService.updateOrder(any<app_models.Order>())).called(1);
    });

    test('Assign order to rider', () async {
      when(() => orderService.assignToRider('order123', 'rider1'))
          .thenAnswer((_) async => Future.value());

      await orderService.assignToRider('order123', 'rider1');
      verify(() => orderService.assignToRider('order123', 'rider1')).called(1);
    });

    test('Cancel order with null reason', () async {
      when(() => orderService.cancelOrder('order123', reason: any(named: 'reason')))
          .thenAnswer((_) async => Future.value());

      await orderService.cancelOrder('order123', reason: null);
      verify(() => orderService.cancelOrder('order123', reason: null)).called(1);
    });

    test('Get order by ID', () async {
      final mockOrder = app_models.Order(
        id: 'order123',
        customerUid: 'user1',
        customerName: 'Test User',
        customerPhone: '01700000000',
        items: [],
        subtotal: 1000.0,
        deliveryFee: 50.0,
        discount: 0.0,
        total: 1050.0,
        address: '123 Street',
        paymentMethod: 'card',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      when(() => orderService.getOrderById('order123'))
          .thenAnswer((_) async => mockOrder);

      final result = await orderService.getOrderById('order123');
      expect(result?.id, 'order123');
      expect(result?.status, app_models.OrderStatus.pending);
    });

    test('Update order status', () async {
      when(() => orderService.updateOrderStatus('order123', 'shipped'))
          .thenAnswer((_) async => Future.value());

      await orderService.updateOrderStatus('order123', 'shipped');
      verify(() => orderService.updateOrderStatus('order123', 'shipped'))
          .called(1);
    });

    test('Cancel order', () async {
      when(() => orderService.cancelOrder('order123', reason: any(named: 'reason')))
          .thenAnswer((_) async => Future.value());

      await orderService.cancelOrder('order123', reason: 'Change of mind');
      verify(() => orderService.cancelOrder('order123', reason: 'Change of mind'))
          .called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // Real-OrderService smoke tests. The new `placeOrder` flow routes through
  // Cloud Functions (`calcOrder` → `reserveStock` → `createOrder`) which
  // cannot be exercised in unit tests without a full CloudFunctionsClient
  // mock wiring. These smoke tests cover the constructor and the
  // unauthenticated guard — both of which run without touching Cloud
  // Functions.
  //
  // TODO(rest_of_tests): rewrite with full mock of CloudFunctionsClient
  // (stub `calcOrder` → canned `PricingSnapshot`, `reserveStock` → canned
  // `ReservationResult`, `createOrder` → canned orderId) to exercise the
  // happy-path three-call orchestration end-to-end.
  // ---------------------------------------------------------------------------
  group('OrderService.placeOrder (real-instance smoke tests)', () {
    late _MockFirebaseAuth mockAuth;
    late _MockCloudFunctionsClient mockCf;
    late _MockFirebaseFirestore mockFirestore;

    setUp(() {
      mockAuth = _MockFirebaseAuth();
      mockCf = _MockCloudFunctionsClient();
      mockFirestore = _MockFirebaseFirestore();
    });

    test('can be constructed with mock dependencies', () {
      expect(
        () => OrderService(
          cf: mockCf,
          firestore: mockFirestore,
          auth: mockAuth,
        ),
        returnsNormally,
      );
    });

    test('throws StateError when no user is authenticated', () async {
      // `FirebaseAuth.currentUser` defaults to null on a fresh mock — but
      // explicit stub makes the test resilient to mocktail's
      // `MissingStubError` behaviour on unstubbed getters.
      when(() => mockAuth.currentUser).thenReturn(null);

      final svc = OrderService(
        cf: mockCf,
        firestore: mockFirestore,
        auth: mockAuth,
      );

      expect(
        () => svc.placeOrder(
          items: const [CartItemRequest(productId: 'P1', quantity: 1)],
          addressId: 'addr-1',
          paymentMethod: PaymentMethod.cod,
          couponCode: null,
          businessId: null,
          note: null,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
