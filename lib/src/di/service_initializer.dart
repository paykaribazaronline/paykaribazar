import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'service_locator.dart';

// Core Services
import '../core/services/secrets_service.dart';
import '../core/services/connectivity_service.dart';
import '../core/services/storage_service.dart';
import '../core/services/permission_service.dart';
import '../core/services/error_reporter_service.dart';
import '../core/services/health_check_service.dart';
import '../core/services/cache_service.dart';
import '../core/services/security_initializer.dart'; // Security initialization
import '../core/admin/dynamic_feature_control.dart'; // Dynamic UI/Feature Control

// Firebase Services
import '../core/firebase/firebase_core_service.dart';
import '../core/firebase/firebase_billing_monitor.dart';
import '../core/firebase/firestore_service.dart';
import '../core/firebase/firebase_auth_service.dart';
import '../core/firebase/firebase_messaging_service.dart';

// Shared & Feature Services
import '../shared/services/notification_service.dart';
import '../shared/services/location_service.dart';
import '../shared/services/media_service.dart';
import '../shared/services/map_service.dart';
import '../shared/services/update_service.dart';
import '../services/background_task_service.dart';
import '../shared/services/payment_service.dart';
import '../features/auth/services/auth_service.dart';
import '../features/ai/services/ai_service.dart';
import '../features/ai/services/ai_audit_service.dart';
import '../features/ai/services/ai_automation_service.dart';
import '../features/ai/services/api_quota_service.dart';
import '../features/ai/services/forecasting_service.dart';
import '../features/commerce/services/cart_service.dart';
import '../features/commerce/services/cart_pos_service.dart';
import '../features/commerce/services/order_service.dart';
import '../features/commerce/services/product_service.dart';
import '../features/commerce/services/loyalty_service.dart';
import '../features/wishlist/services/wishlist_service.dart';
import '../features/logistics/services/delivery_service.dart';
import '../features/logistics/services/geofencing_service.dart';
import '../features/qibla/services/compass_service.dart';
import '../services/chat_service.dart';
import '../services/sync_service.dart';
import '../services/notice_service.dart';
import '../services/auto_translation_service.dart';
import '../services/fleet_service.dart';
import '../services/user_media_service.dart';
import '../features/ota/services/ota_service.dart';

class ServiceInitializer {
  static Future<void> initialize() async {
    // Phase 1: Core
    final sharedPrefs = await SharedPreferences.getInstance();
    getIt.registerLazySingleton<StorageService>(
        () => SharedPrefsService(sharedPrefs));

    final cacheService = CacheService();
    await cacheService.init();
    getIt.registerSingleton<CacheService>(cacheService);

    getIt.registerLazySingleton<SecretsService>(() => SecretsService({}));
    getIt.registerLazySingleton<ConnectivityService>(
        () => ConnectivityService());
    getIt.registerLazySingleton<PermissionService>(() => PermissionService());
    getIt.registerLazySingleton<ErrorReporterService>(
        () => ErrorReporterService());
    getIt.registerLazySingleton<HealthCheckService>(() => HealthCheckService());
    
    // ⭐ CRITICAL: Initialize security services (encryption, biometric auth, API security)
    // This must be called before auth service is used!
    await SecurityInitializer.initializeSecurityServices();

    // Phase 2: Firebase
    final firebaseCore = FirebaseCoreService();
    await firebaseCore.initialize();
    getIt.registerLazySingleton<FirebaseCoreService>(() => firebaseCore);

    // DNA ENFORCED: Activate App Check before using any Firebase services
    // বাংলা: কোনো ফায়ারবেস সার্ভিস ব্যবহারের আগে অ্যাপ চেক চালু করা হয়েছে
    // NOTE: Shorebird preview তে kDebugMode=false হয় কিন্তু Play Integrity
    // কাজ করে না (Play Store certified না)। তাই debug/profile উভয়তেই
    // debug provider ব্যবহার করা হচ্ছে।
    try {
      const isRelease = !kDebugMode && !kProfileMode;
      await FirebaseAppCheck.instance.activate(
        androidProvider: isRelease ? AndroidProvider.playIntegrity : AndroidProvider.debug,
        appleProvider: isRelease ? AppleProvider.deviceCheck : AppleProvider.debug,
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ App Check activation failed (non-fatal): $e');
    }

    getIt.registerLazySingleton<FirestoreService>(() => FirestoreService());
    getIt.registerLazySingleton<FirebaseAuthService>(
        () => FirebaseAuthService());
    getIt.registerLazySingleton<FirebaseMessagingService>(
        () => FirebaseMessagingService());
    
    // Firebase Billing Monitor (tracks usage and costs)
    final billingMonitor = FirebaseBillingMonitor();
    try {
      await billingMonitor.initialize().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('⚠️ BillingMonitor init failed (non-fatal): $e');
    }
    getIt.registerLazySingleton<FirebaseBillingMonitor>(() => billingMonitor);
    
    // Dynamic Feature Control (admin controls for customer app)
    final featureControl = DynamicFeatureControl();
    try {
      await featureControl.initialize().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('⚠️ DynamicFeatureControl init failed (non-fatal): $e');
    }
    getIt.registerLazySingleton<DynamicFeatureControl>(() => featureControl);

    // Phase 3: Shared
    final notificationService = NotificationService();
    try {
      await notificationService.init().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('⚠️ NotificationService init failed (non-fatal): $e');
    }
    getIt.registerLazySingleton<NotificationService>(() => notificationService);

    getIt.registerLazySingleton<LocationService>(() => LocationService());
    getIt.registerLazySingleton<MediaService>(
        () => MediaService(getIt<SecretsService>()));
    getIt.registerLazySingleton<UserMediaService>(
        () => UserMediaService(getIt<MediaService>()));
    getIt.registerLazySingleton<MapService>(() => MapService());
    getIt.registerLazySingleton<UpdateService>(() => UpdateService());
    getIt.registerLazySingleton<BackgroundTaskService>(
        () => BackgroundTaskService());
    getIt.registerLazySingleton<PaymentService>(() => PaymentServiceImpl());
    getIt.registerLazySingleton<FleetService>(() => FleetService());
    
    // Initialize OTA Service
    final otaService = OTAService();
    try {
      await otaService.initialize().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('⚠️ OTAService init failed (non-fatal): $e');
    }

    // Phase 4: Feature Services
    getIt.registerLazySingleton<AuthService>(() => AuthService(
          storage: getIt<StorageService>(),
          firestore: getIt<FirestoreService>(),
        ));
    getIt.registerLazySingleton<AIService>(() => AIService(
          firestore: getIt<FirestoreService>(),
          secrets: getIt<SecretsService>(),
        ));
    getIt.registerLazySingleton<AIAuditService>(() => AIAuditService());
    getIt.registerLazySingleton<AiAutomationService>(() => AiAutomationService());
    getIt.registerLazySingleton<ApiQuotaService>(() => ApiQuotaService());
    getIt.registerLazySingleton<ForecastingService>(() => ForecastingService());
    getIt.registerLazySingleton<CartService>(() => CartService());
    getIt.registerLazySingleton<CartPosService>(() => CartPosService());
    getIt.registerLazySingleton<OrderService>(() => OrderService());
    getIt.registerLazySingleton<ProductService>(() => ProductService());
    getIt.registerLazySingleton<LoyaltyService>(() => LoyaltyService());
    getIt.registerLazySingleton<WishlistService>(() => WishlistService());
    getIt.registerLazySingleton<DeliveryService>(() => DeliveryService());
    getIt.registerLazySingleton<GeofencingService>(() => GeofencingService());
    getIt.registerLazySingleton<CompassService>(
        () => CompassService(getIt<LocationService>()));

    // Additional Services
    getIt.registerLazySingleton<ChatService>(() => ChatService());
    getIt.registerLazySingleton<SyncService>(() => SyncService());
    getIt.registerLazySingleton<NoticeService>(() => NoticeService());
    getIt.registerLazySingleton<AutoTranslationService>(
        () => AutoTranslationService());
    
    // ⭐ SecureAuthService already initialized in Phase 1 via SecurityInitializer
    // No need for duplicate initialization - this was causing GetIt registration issues
  }
}
