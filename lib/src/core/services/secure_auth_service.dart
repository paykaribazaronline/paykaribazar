import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:async';
import 'package:flutter/material.dart';

/// Service for biometric authentication and secure credential storage
/// Handles: fingerprint, face recognition, and secure token management
class SecureAuthService {
  final LocalAuthentication _localAuth = LocalAuthentication();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );

  // Cache for biometric availability to avoid repeated checks
  bool? _biometricAvailable;
  List<BiometricType>? _availableBiometrics;

  /// Initialize biometric capabilities
  Future<void> initialize() async {
    try {
      _biometricAvailable = await _localAuth.canCheckBiometrics;
      if (_biometricAvailable == true) {
        _availableBiometrics = await _localAuth.getAvailableBiometrics();
        debugPrint(
          '✅ Biometric initialized: ${_availableBiometrics?.map((e) => e.name).join(", ")}',
        );
      } else {
        debugPrint('⚠️ Biometric not available on this device');
      }
    } catch (e) {
      debugPrint('❌ Biometric initialization failed: $e');
      _biometricAvailable = false;
    }
  }

  /// Check if device supports biometric authentication
  Future<bool> isBiometricAvailable() async {
    _biometricAvailable ??= await _localAuth.canCheckBiometrics;
    return _biometricAvailable ?? false;
  }

  /// Get available biometric types (fingerprint, face, etc.)
  Future<List<BiometricType>> getAvailableBiometrics() async {
    _availableBiometrics ??= await _localAuth.getAvailableBiometrics();
    return _availableBiometrics ?? [];
  }

  /// Authenticate user with biometric (fingerprint, face, etc.)
  Future<bool> authenticateForPayment({
    String localizedReason = 'Please authenticate to complete payment',
    bool useErrorDialogs = true,
  }) async {
    try {
      if (!await isBiometricAvailable()) {
        debugPrint('⚠️ Biometric not available');
        return false;
      }

      // local_auth 3.x removed `AuthenticationOptions` — its fields are now
      // top-level named parameters on `authenticate()` directly. We pass
      // `stickyAuth: true` so the auth state survives a lifecycle pause
      // (e.g. the system showing the biometric prompt).
      return await _localAuth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          stickyAuth: true,
        ),
      );
    } catch (e) {
      debugPrint('❌ Biometric authentication failed: $e');
      return false;
    }
  }

  /// Authenticate for sensitive operations
  Future<bool> authenticateForSensitiveOperation({
    String localizedReason = 'Verify your identity to proceed',
  }) async {
    try {
      return await _localAuth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          stickyAuth: true,
        ),
      );
    } catch (e) {
      debugPrint('❌ Sensitive operation authentication failed: $e');
      return false;
    }
  }

  // Secure Storage Operations...
  Future<void> storeSecureToken(String key, String token) async {
    await _secureStorage.write(key: key, value: token);
  }

  Future<String?> getSecureToken(String key) async {
    return await _secureStorage.read(key: key);
  }

  Future<void> deleteSecureData(String key) async {
    await _secureStorage.delete(key: key);
  }

  Future<void> clearAllSecureData() async {
    await _secureStorage.deleteAll();
  }

  /// Get device biometric info for debugging
  Future<Map<String, dynamic>> getBiometricInfo() async {
    final bool canCheck = await isBiometricAvailable();
    return {
      'available': canCheck,
      'biometrics': await getAvailableBiometrics(),
      'isDeviceSupported': await _localAuth.isDeviceSupported(),
    };
  }
}
