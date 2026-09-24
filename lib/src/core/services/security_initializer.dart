import 'package:get_it/get_it.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart';
import 'secure_auth_service.dart';
import 'encryption_service.dart';
import 'api_security_service.dart';

/// ---------------------------------------------------------------------------
/// Security services initialization.
///
/// SECURITY NOTE (Task ID 3-4-5-6):
/// These credentials were previously embedded in the client binary via
/// `.env` files shipped in `assets/` and via hard-coded fallbacks in this
/// file. ALL secrets have moved to Cloud Functions env config / Secret
/// Manager (see `functions/.env.example`). The client-side
/// [APISecurityService] is retained only for legacy local cache signing
/// (the local-only `flutter_secure_storage` keyed values) and MUST NOT
/// hold any production secret.
///
/// In release mode, missing credentials are FATAL — `initialize()` throws
/// and the app refuses to boot. In debug mode, a clearly-named dev-only key
/// / empty string is used so local development continues to work.
/// ---------------------------------------------------------------------------
class SecurityInitializer {
  static final getIt = GetIt.instance;

  /// Initialize all security services
  /// This should be called early during app startup (Phase 1)
  static Future<void> initializeSecurityServices() async {
    try {
      if (kDebugMode) debugPrint('🔐 [SecurityInitializer] Starting security services initialization...');

      // Helper to safely access dotenv without throwing NotInitializedError
      String? getEnv(String key) {
        try {
          return dotenv.env[key];
        } catch (_) {
          return null;
        }
      }

      // 1. Initialize encryption service — key from .env
      if (!getIt.isRegistered<EncryptionService>()) {
        final encKey = getEnv('ENCRYPTION_KEY');
        final String effectiveKey;
        if (encKey != null && encKey.isNotEmpty) {
          effectiveKey = encKey;
        } else if (kDebugMode) {
          // DEV-ONLY fallback — clearly named so a production grep catches it.
          effectiveKey = 'DEV_ONLY_NOT_FOR_PRODUCTION_32ByteKeY!!';
        } else {
          throw StateError(
            '❌ ENCRYPTION_KEY missing in production environment — '
            'refusing to boot. Set ENCRYPTION_KEY via Secret Manager before '
            'assembling the release build.',
          );
        }
        getIt.registerSingleton<EncryptionService>(EncryptionService(effectiveKey));
        if (kDebugMode) debugPrint('✅ [SecurityInitializer] EncryptionService registered');
      }

      // 2. Initialize API security service — credentials from .env
      // NOTE (Task ID 3-4-5-6): the previous hardcoded fallbacks
      // ('paykari_bazar_api_key' / 'paykari_bazar_api_secret_key_1234567890')
      // have been removed. The client-side APISecurityService is retained
      // only for legacy local cache signing; all real API calls now go
      // through the backend callables, which use their own server-side
      // secret store. In release mode we throw if env is missing.
      if (!getIt.isRegistered<APISecurityService>()) {
        final apiKey = getEnv('API_KEY');
        final apiSecret = getEnv('API_SECRET');
        final String effApiKey;
        final String effApiSecret;
        if (apiKey != null && apiKey.isNotEmpty &&
            apiSecret != null && apiSecret.isNotEmpty) {
          effApiKey = apiKey;
          effApiSecret = apiSecret;
        } else if (kDebugMode) {
          // Empty string is safe — APISecurityService will refuse to sign
          // requests, and all real requests now go through Cloud Functions.
          effApiKey = '';
          effApiSecret = '';
        } else {
          throw StateError(
            '❌ API_KEY / API_SECRET missing in production environment — '
            'refusing to boot. Configure via Secret Manager before assembling '
            'the release build.',
          );
        }
        getIt.registerSingleton<APISecurityService>(
          APISecurityService(apiKey: effApiKey, apiSecret: effApiSecret),
        );
        if (kDebugMode) debugPrint('✅ [SecurityInitializer] APISecurityService registered');
      }

      // 3. Initialize secure auth service and check biometric
      if (!getIt.isRegistered<SecureAuthService>()) {
        if (kDebugMode) debugPrint('🔄 [SecurityInitializer] Creating and initializing SecureAuthService...');
        final secureAuthService = SecureAuthService();
        try {
          await secureAuthService.initialize();
          if (kDebugMode) debugPrint('✅ [SecurityInitializer] SecureAuthService initialized (biometric check complete)');
        } catch (initError) {
          if (kDebugMode) debugPrint('⚠️ [SecurityInitializer] SecureAuthService initialization warning: $initError (non-critical)');
          // Non-critical error - app can continue without biometric
        }
        getIt.registerSingleton<SecureAuthService>(secureAuthService);
        if (kDebugMode) debugPrint('✅ [SecurityInitializer] SecureAuthService registered in GetIt');
      }

      if (kDebugMode) debugPrint('🟢 [SecurityInitializer] All security services initialized successfully');
    } catch (e, stack) {
      if (kDebugMode) debugPrint('🔴 [SecurityInitializer] Security initialization FAILED: $e');
      if (kDebugMode) debugPrint('Stack: $stack');
      rethrow;
    }
  }

  /// Get instances of security services
  /// These methods safely access GetIt with proper error messages
  static SecureAuthService get secureAuth {
    try {
      return getIt<SecureAuthService>();
    } catch (e) {
      debugPrint('❌ [SecurityInitializer.secureAuth] GetIt lookup failed: $e');
      throw Exception('SecureAuthService not registered in GetIt. Please ensure ServiceInitializer.initialize() was called. Error: $e');
    }
  }

  static EncryptionService get encryption {
    try {
      return getIt<EncryptionService>();
    } catch (e) {
      throw Exception('EncryptionService not registered in GetIt. Error: $e');
    }
  }

  static APISecurityService get apiSecurity {
    try {
      return getIt<APISecurityService>();
    } catch (e) {
      throw Exception('APISecurityService not registered in GetIt. Error: $e');
    }
  }

  /// Verify all services are properly registered
  static bool areAllServicesRegistered() {
    return getIt.isRegistered<SecureAuthService>() &&
        getIt.isRegistered<EncryptionService>() &&
        getIt.isRegistered<APISecurityService>();
  }
}
