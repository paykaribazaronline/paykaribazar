import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../shared/services/media_service.dart';
import '../services/user_media_service.dart'; // Assuming this is a general service
import '../core/constants/paths.dart';
import 'dart:async';
import '../core/services/cache_service.dart';
import 'package:flutter/foundation.dart';
// Note: role_simulator_provider.dart is intentionally NOT re-exported here.
// It's imported directly by auth_providers.dart and teams_tab.dart; re-exporting
// it caused `simulatedUserUidProvider` to become ambiguous in consumer files
// that import providers.dart and (transitively) auth_providers.dart.
// If a consumer needs simulatedUserUidProvider, it should import
// role_simulator_provider.dart directly.
import '../core/firebase/firestore_service.dart';
import '../core/firebase/firebase_billing_monitor.dart';
import '../core/services/health_check_service.dart';
import '../core/services/secrets_service.dart';
import '../shared/services/notification_service.dart';
import '../shared/services/location_service.dart';
import '../shared/services/update_service.dart';
import '../services/sync_service.dart';
import '../services/notice_service.dart';
import '../services/auto_translation_service.dart';
import '../services/chat_service.dart';
import '../features/qibla/services/compass_service.dart';
import '../features/ota/services/ota_service.dart';
import '../services/backup_service.dart';
import 'service_locator.dart';
import '../features/ai/services/ai_service.dart';
import '../features/ai/services/ai_automation_service.dart';
import '../features/ai/services/api_quota_service.dart';
import '../features/ai/services/forecasting_service.dart';
import '../features/commerce/services/loyalty_service.dart';
import '../features/logistics/services/delivery_service.dart';
import '../services/fleet_service.dart';
import '../features/auth/providers/auth_providers.dart';

// --- MODELS & TYPES ---
export '../core/constants/paths.dart';
export '../features/commerce/domain/cart_model.dart' show CartState, CartItem;
export '../features/ai/domain/ai_work_type.dart';
export '../shared/services/update_service.dart' show UpdateStatus;
export '../features/commerce/providers/cart_provider.dart'
    show
        businessRulesProvider,
        cartProvider,
        cartSubtotalProvider,
        cartMinimumOrderValueProvider,
        cartShortfallProvider,
        cartDeliveryFeeProvider,
        cartDiscountProvider,
        cartPointsDiscountProvider,
        cartTotalProvider,
        CartNotifier,
        CartState,
        selectedAddressIdProvider;
export '../services/language_provider.dart' show languageProvider;
export '../services/nav_provider.dart' show navProvider;
export '../services/theme_provider.dart' show themeProvider;
export '../core/exceptions/app_exceptions.dart';

// --- FEATURE-SPECIFIC PROVIDERS (exported from their files) ---
export '../features/auth/providers/auth_providers.dart';
export '../features/wishlist/providers/wishlist_provider.dart';

// --- PROVIDERS ---

// Firebase instances
final firebaseFirestoreProvider = Provider((ref) => FirebaseFirestore.instance);
final firebaseAuthProvider = Provider((ref) => FirebaseAuth.instance);

// Core Services wired through GetIt (registered in di/service_initializer.dart).
// All these services have constructor dependencies that are themselves
// resolved by GetIt, so we route every provider through getIt<T>() rather
// than instantiating directly — this preserves the singleton semantics and
// keeps constructor signature drift (e.g. SecretsService gaining a Map arg)
// from breaking the provider layer.
final firestoreService = Provider((ref) => getIt<FirestoreService>());
final firestoreServiceProvider = firestoreService; // Alias

// Services wired through GetIt (registered in di/service_initializer.dart)
final aiServiceProvider = Provider<AIService>((ref) => getIt<AIService>());
final aiAutomationProvider =
    Provider<AiAutomationService>((ref) => getIt<AiAutomationService>());
final apiQuotaServiceProvider =
    Provider((ref) => getIt<ApiQuotaService>());
final loyaltyServiceProvider =
    Provider<LoyaltyService>((ref) => getIt<LoyaltyService>());
final deliveryServiceProvider =
    Provider((ref) => getIt<DeliveryService>());
final fleetServiceProvider = Provider((ref) => getIt<FleetService>());
final forecastingServiceProvider =
    Provider((ref) => getIt<ForecastingService>());

final notificationServiceProvider = Provider((ref) => NotificationService());
final locationServiceProvider = Provider((ref) => LocationService());
final billingMonitorProvider = Provider((ref) => FirebaseBillingMonitor());
final secretsServiceProvider = Provider((ref) => getIt<SecretsService>());
final updateServiceProvider = Provider((ref) => UpdateService());
final syncServiceProvider = Provider((ref) => SyncService());
final noticeServiceProvider = Provider((ref) => NoticeService());
final autoTranslationProvider = Provider((ref) => AutoTranslationService());
final chatServiceProvider = Provider((ref) => getIt<ChatService>());
final compassServiceProvider = Provider((ref) => getIt<CompassService>());
final otaServiceProvider = Provider((ref) => OTAService()); // OTAService might not need dependencies
final mediaServiceProvider = Provider((ref) => getIt<MediaService>());
final userMediaServiceProvider = Provider((ref) => getIt<UserMediaService>());
final healthCheckProvider = FutureProvider<Map<String, dynamic>>(
    (ref) => getIt<HealthCheckService>().checkSystemHealth());

final backupServiceProvider = Provider((ref) {
  final secrets = ref.watch(secretsServiceProvider);
  final masterKey = secrets.getSecret('backup_master_key', fallback: 'paykari_bazar_secure_master_key_!');
  return BackupService(masterKey.padRight(32).substring(0, 32));
});

// Role Simulator providers are exported from '../services/role_simulator_provider.dart'

class WishlistNotifier extends StateNotifier<List<String>> {
  WishlistNotifier() : super([]);
  void toggle(String id) {
    if (state.contains(id)) {
      state = state.where((i) => i != id).toList();
    } else {
      state = [...state, id];
    }
  }
}

final productsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  final cacheService = getIt<CacheService>();
  final controller = StreamController<List<Map<String, dynamic>>>();

  // Load from cache initially as fallback
  cacheService.get<List<dynamic>>('products_cache').then((cached) {
    if (cached != null && !controller.isClosed) {
      final products = cached.map((p) => Map<String, dynamic>.from(p)).toList();
      controller.add(products);
    }
  });

  // Listen to Firestore
  final sub = FirebaseFirestore.instance.collection(HubPaths.products)
      .where('isDeleted', isNotEqualTo: true)
      .snapshots().listen(
    (snap) {
      final products = snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
      if (products.isNotEmpty) {
        cacheService.set(key: 'products_cache', value: products);
      }
      if (!controller.isClosed) {
        controller.add(products);
      }
    },
    onError: (error) async {
      if (kDebugMode) debugPrint('Firestore products stream error, checking cache fallback: $error');
      final cached = await cacheService.get<List<dynamic>>('products_cache');
      if (cached != null && !controller.isClosed) {
        final products = cached.map((p) => Map<String, dynamic>.from(p)).toList();
        controller.add(products);
      } else if (!controller.isClosed) {
        controller.addError(error);
      }
    },
  );

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});

final categoriesProvider = StreamProvider<List<Map<String, dynamic>>>((ref) { // Assuming this is a core data provider
  return FirebaseFirestore.instance.collection(HubPaths.categories).snapshots().map((snap) => snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
});

final storesProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  return FirebaseFirestore.instance.collection(HubPaths.stores).orderBy('order').snapshots().map((snap) => snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
});

final ordersProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  // Guarded to prevent PERMISSION_DENIED console logs
  final user = ref.watch(authStateProvider).value;
  if (user == null) return Stream.value(<Map<String, dynamic>>[]);
  final userData = ref.watch(currentUserDataProvider).value;
  final role = userData?['role'] ?? 'customer';
  if (role != 'admin' && role != 'staff') return Stream.value(<Map<String, dynamic>>[]); // Only admins/staff can see all orders
  return FirebaseFirestore.instance.collection(HubPaths.orders).orderBy('createdAt', descending: true).snapshots().map((snap) => snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
});

final locationsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  return FirebaseFirestore.instance.collection(HubPaths.locations).snapshots().map((snap) => snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
});

final visibleLocationsProvider = Provider<AsyncValue<List<Map<String, dynamic>>>>((ref) {
  return ref.watch(locationsProvider).whenData((locs) {
    // Treat missing 'isVisible' as true (Visible by default)
    // বাংলা: 'isVisible' ফিল্ড না থাকলে সেটাকে ট্রু (দৃশ্যমান) হিসেবে ধরা হবে
    return locs.where((l) {
      final isVisible = l['isVisible'];
      return isVisible == true || isVisible == null;
    }).toList();
  });
});

// --- ADMIN & MISC ---
final allCommissionsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final snap = await FirebaseFirestore.instance.collection('commissions').get();
  return snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
});

final groupedAiAuditProvider = FutureProvider<Map<String, dynamic>>((ref) async { // Assuming this is a core admin provider
  final snap = await FirebaseFirestore.instance.collection('ai_audit_logs').get();
  final docs = snap.docs.map((doc) => doc.data()).toList();
  return {'total': docs.length, 'logs': docs, 'stats': {'success': docs.where((d) => d['status'] == 'success').length, 'failed': docs.where((d) => d['status'] == 'failed').length}};
});

final aiAuditLogsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  // Guarded to prevent PERMISSION_DENIED console logs when logged out or during auto-logout redirection
  final user = ref.watch(authStateProvider).value;
  if (user == null) return Stream.value(<Map<String, dynamic>>[]);
  final userData = ref.watch(currentUserDataProvider).value;
  final role = userData?['role'] ?? 'customer';
  if (role != 'admin') return Stream.value(<Map<String, dynamic>>[]);
  return FirebaseFirestore.instance.collection('ai_audit_logs').orderBy('timestamp', descending: true).snapshots().map((snap) => snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
});
final featureFlagsProvider = StreamProvider<Map<String, dynamic>>((ref) {
  return FirebaseFirestore.instance
      .doc('_system/admin/featureFlags/all')
      .snapshots()
      .map((snap) => snap.data() ?? {});
});

final firebaseBillingMetricsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final monitor = ref.watch(billingMonitorProvider);
  return monitor.getCurrentMetrics();
});

final firebaseUsageMetricsProvider = FutureProvider<UsageMetricsPage>((ref) async {
  final monitor = ref.watch(billingMonitorProvider);
  return monitor.getUsageMetrics(pageSize: 10);
});

final remoteLocalizationProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final snap = await FirebaseFirestore.instance.doc(HubPaths.localizationDoc).get();
  return snap.data() ?? {};
});

final appConfigProvider = StreamProvider<Map<String, dynamic>>((ref) {
  return FirebaseFirestore.instance.doc(HubPaths.configDoc).snapshots().map((snap) => snap.data() ?? {});
});

final appSettingsProvider = appConfigProvider;

final loyaltySettingsProvider = StreamProvider<Map<String, dynamic>>((ref) {
  return FirebaseFirestore.instance.doc(HubPaths.loyaltyDoc).snapshots().map((snap) => snap.data() ?? {});
});

// --- AI / API QUOTA DASHBOARD PROVIDERS ---
// Reads the per-key quota state stored at `settings/api_quota` so admin
// dashboards can render usage / exhaustion without a separate callable.
final apiQuotaStreamProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  return FirebaseFirestore.instance.collection('settings').doc('api_quota').snapshots().map((snap) {
    final data = snap.data();
    if (data == null || data['keys'] == null) return <Map<String, dynamic>>[];
    return (data['keys'] as List).map((k) => Map<String, dynamic>.from(k)).toList();
  });
});

/// Aggregated counts derived from [apiQuotaStreamProvider]. Exposed as a
/// plain `Provider<Map>` (not `AsyncValue`) so dashboard widgets can read it
/// directly without `.when(...)`.
final apiQuotaSummaryProvider = Provider<Map<String, dynamic>>((ref) {
  final quotas = ref.watch(apiQuotaStreamProvider).value ?? const [];
  if (quotas.isEmpty) {
    return {
      'totalKeys': 0,
      'activeKeys': 0,
      'exhaustedKeys': 0,
      'totalUsage': 0,
      'totalLimit': 0,
      'usagePercent': 0.0,
    };
  }

  int totalUsage = 0;
  int totalLimit = 0;
  int activeKeys = 0;
  int exhaustedKeys = 0;

  for (final quota in quotas) {
    final used = (quota['used_today'] ?? quota['currentUsage'] ?? 0) as num;
    final limit = (quota['daily_limit'] ?? quota['limit'] ?? 0) as num;
    totalUsage += used.toInt();
    totalLimit += limit.toInt();
    if ((quota['status'] ?? 'active') == 'exhausted') {
      exhaustedKeys += 1;
    } else {
      activeKeys += 1;
    }
  }

  return {
    'totalKeys': quotas.length,
    'activeKeys': activeKeys,
    'exhaustedKeys': exhaustedKeys,
    'totalUsage': totalUsage,
    'totalLimit': totalLimit,
    'usagePercent': totalLimit == 0 ? 0.0 : (totalUsage / totalLimit) * 100,
  };
});

/// High-level AI provider status used by the system-health dashboard. Pulls
/// both the [HealthCheckService] core telemetry and the [AIService] provider
/// health snapshot, then collapses them into a single `Map<String, String>`
/// the widget can render without any further transformation.
final aiStatusProvider = FutureProvider<Map<String, String>>((ref) async {
  final health = await getIt<HealthCheckService>().checkSystemHealth();
  final aiHealth = await getIt<AIService>().performGlobalSystemCheck();
  return {
    'NEURAL': aiHealth['status']?.toString().toUpperCase() ?? 'OFFLINE',
    'GATEWAY': health['firebaseLive'] == true ? 'ONLINE' : 'OFFLINE',
    'KEYS': aiHealth['providers_active']?.toString() ?? '0',
    'LOAD': aiHealth['neural_load']?.toString() ?? '0%',
    'LATENCY': aiHealth['latency']?.toString() ?? '0ms',
  };
});

final monthlyTopBuyersProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  return FirebaseFirestore.instance.collection(HubPaths.users).orderBy('points', descending: true).limit(10).snapshots().map((snap) => snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
});

final heroRecordsProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  return FirebaseFirestore.instance.collection('hero_records').orderBy('timestamp', descending: true).snapshots().map((snap) => snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
});

final promoProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  return FirebaseFirestore.instance.collection('promos').snapshots().map((snap) => snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
});
