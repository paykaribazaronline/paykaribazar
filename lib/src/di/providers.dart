import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../shared/services/media_service.dart';
import '../services/user_media_service.dart'; // Assuming this is a general service
import '../core/constants/paths.dart';
import 'dart:async';
import '../core/services/cache_service.dart';
import 'package:flutter/foundation.dart';
import '../services/role_simulator_provider.dart'; // Assuming this is a general service
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

// --- MODELS & TYPES ---
export '../core/constants/paths.dart';
export '../shared/services/update_service.dart' show UpdateStatus;
export '../services/language_provider.dart' show languageProvider;
export '../services/nav_provider.dart' show navProvider;
export '../services/theme_provider.dart' show themeProvider;
export '../core/exceptions/app_exceptions.dart';

// --- FEATURE-SPECIFIC PROVIDERS (exported from their files) ---
export '../features/auth/providers/auth_providers.dart';
export '../features/commerce/providers/commerce_providers.dart';
export '../features/ai/providers/ai_providers.dart';
export '../features/logistics/providers/logistics_providers.dart';
export '../features/wishlist/providers/wishlist_provider.dart';

// --- PROVIDERS ---

// Firebase instances
final firebaseFirestoreProvider = Provider((ref) => FirebaseFirestore.instance);
final firebaseAuthProvider = Provider((ref) => FirebaseAuth.instance);

// Core Services (instantiated directly, assuming their dependencies are also providers)
final firestoreService = Provider((ref) => FirestoreService(ref.watch(firebaseFirestoreProvider)));
final firestoreServiceProvider = firestoreService; // Alias

final notificationServiceProvider = Provider((ref) => NotificationService());
final locationServiceProvider = Provider((ref) => LocationService());
final billingMonitorProvider = Provider((ref) => FirebaseBillingMonitor());
final secretsServiceProvider = Provider((ref) => SecretsService());
final updateServiceProvider = Provider((ref) => UpdateService());
final syncServiceProvider = Provider((ref) => SyncService());
final noticeServiceProvider = Provider((ref) => NoticeService());
final autoTranslationProvider = Provider((ref) => AutoTranslationService());
final chatServiceProvider = Provider((ref) => ChatService(ref.watch(firebaseFirestoreProvider))); // Assuming ChatService needs Firestore
final compassServiceProvider = Provider((ref) => CompassService());
final otaServiceProvider = Provider((ref) => OTAService()); // OTAService might not need dependencies
final mediaServiceProvider = Provider((ref) => MediaService());
final userMediaServiceProvider = Provider((ref) => UserMediaService());
final healthCheckProvider = Provider((ref) => HealthCheckService());

final backupServiceProvider = Provider((ref) {
  final secrets = ref.watch(secretsServiceProvider);
  final masterKey = secrets.getSecret('backup_master_key', fallback: 'paykari_bazar_secure_master_key_!');
  return BackupService(masterKey.padRight(32).substring(0, 32));
});

// Role Simulator (assuming it's a general utility)
final simulatedUserUidProvider = StateProvider<String?>((ref) => null);

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
  return FirebaseFirestore.instance.doc(HubPaths.loyaltyDoc).snapshots().map((snap) => snap.data() ?? {}); // Moved to commerce_providers.dart
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
