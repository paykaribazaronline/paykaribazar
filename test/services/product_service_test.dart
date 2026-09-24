import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:paykari_bazar/src/features/commerce/services/product_service.dart';
import 'package:paykari_bazar/src/models/product_model.dart';

class MockProductService extends Mock implements ProductService {}

void main() {
  group('ProductService Tests', () {
    late MockProductService productService;

    setUp(() {
      productService = MockProductService();
    });

    test('Get product by ID', () async {
      final product = Product(
        id: 'prod1',
        sku: 'SKU001',
        name: 'Test Product',
        nameBn: 'পরীক্ষা পণ্য',
        description: 'Test Description',
        descriptionBn: 'পরীক্ষা বর্ণনা',
        price: 100.0,
        stock: 10,
        unit: 'pcs',
        unitBn: 'পিস',
        imageUrl: '',
        categoryId: 'cat1',
        categoryName: 'Test Category',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      when(() => productService.getProductById(any<String>())).thenAnswer((_) async => product);

      final result = await productService.getProductById('prod1');

      expect(result?.id, 'prod1');
      expect(result?.name, 'Test Product');
    });

    test('Get products stream', () async {
      final products = <Product>[
        Product(
          id: 'p1',
          sku: 'SKU1',
          name: 'A',
          nameBn: 'আ',
          description: 'd',
          descriptionBn: 'ডি',
          price: 10.0,
          stock: 1,
          unit: 'pc',
          unitBn: 'পিস',
          imageUrl: '',
          categoryId: 'c1',
          categoryName: 'Cat',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];
      final productStream = Stream<List<Product>>.value(products);
      when(() => productService.getProducts()).thenAnswer((_) => productStream);

      final result = productService.getProducts();
      final first = await result.first;
      expect(first.length, 1);
      expect(first.first.id, 'p1');
    });

    test('Filter products by category', () async {
      final products = <Product>[
        Product(
          id: 'p1',
          sku: 'SKU1',
          name: 'A',
          nameBn: 'আ',
          description: 'd',
          descriptionBn: 'ডি',
          price: 10.0,
          stock: 1,
          unit: 'pc',
          unitBn: 'পিস',
          imageUrl: '',
          categoryId: 'cat1',
          categoryName: 'Cat',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];
      final productStream = Stream<List<Product>>.value(products);
      when(() => productService.filterByCategory('cat1'))
          .thenAnswer((_) => productStream);

      final result = productService.filterByCategory('cat1');
      final first = await result.first;
      expect(first.length, 1);
      expect(first.first.categoryId, 'cat1');
    });

    // The `updateProductStock` test was removed — the method was deleted
    // from `ProductService` because stock, reservedStock and soldStock are
    // now server-only fields per the new `firestore.rules`. Inventory
    // mutations happen exclusively through the `reserveStock`,
    // `releaseReservation`, and `commitReservation` Cloud Functions.

    test('Search products', () async {
      final productStream = Stream<List<Product>>.value(<Product>[]);
      when(() => productService.searchProducts(any<String>())).thenAnswer((_) => productStream);

      final results = productStream;
      results.listen((productList) {
        expect(productList, isA<List<Product>>());
      });
    });

    group('Product matchesSearch', () {
      final product = Product(
        id: '1',
        sku: 'SKU123',
        name: 'Rice',
        nameBn: 'চাল',
        description: 'Quality rice',
        descriptionBn: 'ভালো চাল',
        price: 50.0,
        stock: 100,
        unit: 'kg',
        unitBn: 'কেজি',
        imageUrl: '',
        categoryId: 'grocery',
        categoryName: 'Grocery',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      test('matches by name', () {
        expect(product.matchesSearch('rice'), isTrue);
      });

      test('matches by nameBn', () {
        expect(product.matchesSearch('চাল'), isTrue);
      });

      test('matches by sku', () {
        expect(product.matchesSearch('SKU123'), isTrue);
      });

      test('matches by category', () {
        expect(product.matchesSearch('grocery'), isTrue);
      });

      test('does not match unrelated query', () {
        expect(product.matchesSearch('mobile'), isFalse);
      });
    });

    group('Product helpers', () {
      test('getPriceForQuantity without tieredPrices', () {
        final product = Product(
          id: 'p1',
          sku: 'SKU1',
          name: 'A',
          nameBn: 'আ',
          description: 'd',
          descriptionBn: 'ডি',
          price: 100.0,
          stock: 10,
          unit: 'pc',
          unitBn: 'পিস',
          imageUrl: '',
          categoryId: 'c1',
          categoryName: 'Cat',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        expect(product.getPriceForQuantity(5), equals(100.0));
      });

      test('hasDiscount true when oldPrice > price', () {
        final product = Product(
          id: 'p1',
          sku: 'SKU1',
          name: 'A',
          nameBn: 'আ',
          description: 'd',
          descriptionBn: 'ডি',
          price: 80.0,
          oldPrice: 100.0,
          stock: 10,
          unit: 'pc',
          unitBn: 'পিস',
          imageUrl: '',
          categoryId: 'c1',
          categoryName: 'Cat',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        expect(product.hasDiscount, isTrue);
        expect(product.discountPercentage, equals(20));
      });

      test('getName returns Bangla when lang is bn', () {
        final product = Product(
          id: 'p1',
          sku: 'SKU1',
          name: 'Rice',
          nameBn: 'চাল',
          description: 'd',
          descriptionBn: 'ডি',
          price: 100.0,
          stock: 10,
          unit: 'pc',
          unitBn: 'পিস',
          imageUrl: '',
          categoryId: 'c1',
          categoryName: 'Cat',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        expect(product.getName('bn'), equals('চাল'));
        expect(product.getName('en'), equals('Rice'));
      });

      test('getCategory returns Bangla category when available', () {
        final product = Product(
          id: 'p1',
          sku: 'SKU1',
          name: 'A',
          nameBn: 'আ',
          description: 'd',
          descriptionBn: 'ডি',
          price: 100.0,
          stock: 10,
          unit: 'pc',
          unitBn: 'পিস',
          imageUrl: '',
          categoryId: 'c1',
          categoryName: 'Grocery',
          categoryNameBn: 'মুদ征',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        expect(product.getCategory('bn'), equals('মুদ征'));
        expect(product.getCategory('en'), equals('Grocery'));
      });
    });
  });
}
