import 'package:flutter_test/flutter_test.dart';
import 'package:paykari_bazar/src/core/services/cache_service.dart';
import 'package:hive_flutter/hive_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  @override
  Future<String?> getApplicationDocumentsPath() async => '.';
  @override
  Future<String?> getTemporaryPath() async => '.';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = MockPathProvider();

  group('CacheService Tests', () {
    late CacheService cache;

    setUp(() async {
      await Hive.initFlutter();
      cache = CacheService();
      await cache.init();
    });

    tearDown(() async {
      await cache.clearAll();
      await Hive.close();
    });

    group('Basic Operations', () {
      test('set and get value', () async {
        await cache.set(key: 'key1', value: 'value1');
        final result = await cache.get<String>('key1');
        expect(result, equals('value1'));
      });

      test('get non-existent key returns null', () async {
        final result = await cache.get<String>('nonexistent');
        expect(result, isNull);
      });

      test('set overwrites existing value', () async {
        await cache.set(key: 'key1', value: 'value1');
        await cache.set(key: 'key1', value: 'value2');
        final result = await cache.get<String>('key1');
        expect(result, equals('value2'));
      });

      test('delete removes key', () async {
        await cache.set(key: 'key1', value: 'value1');
        await cache.delete('key1');
        final result = await cache.get<String>('key1');
        expect(result, isNull);
      });

      test('clearAll removes all entries', () async {
        await cache.set(key: 'key1', value: 'value1');
        await cache.set(key: 'key2', value: 'value2');
        await cache.clearAll();
        expect(await cache.get<String>('key1'), isNull);
        expect(await cache.get<String>('key2'), isNull);
      });
    });

    group('Time-Based Expiration', () {
      test('expired items return null', () async {
        await cache.set(
          key: 'expire_key', 
          value: 'value1', 
          ttl: const Duration(seconds: 1)
        );

        final val = await cache.get<String>('expire_key');
        expect(val, equals('value1'));

        // Wait for expiration
        await Future.delayed(const Duration(seconds: 2));

        final expiredVal = await cache.get<String>('expire_key');
        expect(expiredVal, isNull);
      });
    });

    group('Statistics', () {
      test('getStats returns correct metrics', () async {
        await cache.set(key: 's1', value: 'v1');
        await cache.set(key: 's2', value: 'v2');

        final stats = await cache.getStats();

        expect(stats.totalItems, equals(2));
        expect(stats.validItems, equals(2));
      });
    });
  });
}
