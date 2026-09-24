// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:convert';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../features/checkout/models/pricing_snapshot.dart';
import '../../features/payments/models/payment_init.dart';
import '../../features/payments/models/payment_method.dart';
import '../../features/payments/models/payment_result.dart';

/// Region must match the backend deploy region (see `functions/src/index.ts`).
const String _kFunctionsRegion = 'asia-southeast1';

/// ---------------------------------------------------------------------------
/// Typed exceptions. `FirebaseFunctionsException` is mapped to one of these
/// so the UI layer can render a Bangla message instead of leaking the raw
/// English `details` payload.
/// ---------------------------------------------------------------------------

class PaykariCloudFunctionException implements Exception {
  final String code;
  final String message;
  final String banglaMessage;
  final Object? details;
  const PaykariCloudFunctionException(
    this.code,
    this.message, {
    this.banglaMessage = 'কিছু সমস্যা হয়েছে। আবার চেষ্টা করুন।',
    this.details,
  });

  @override
  String toString() => 'PaykariCloudFunctionException($code): $message';
}

class InsufficientStockException extends PaykariCloudFunctionException {
  final String? productId;
  final int? available;
  final int? wanted;
  InsufficientStockException(String message,
      {this.productId,
      this.available,
      this.wanted,
      String? bangla,
      Object? details})
      : super('insufficient-stock', message,
            banglaMessage: bangla ?? 'পর্যাপ্ত পণ্য নেই। কিছুক্ষণ পর আবার চেষ্টা করুন।',
            details: details);
}

class PricingExpiredException extends PaykariCloudFunctionException {
  PricingExpiredException(String message, {Object? details})
      : super('pricing-expired', message,
          banglaMessage: 'দাম পরিবর্তন হয়েছে। আবার চেষ্টা করুন।',
          details: details);
}

class PricingSignatureInvalidException extends PaykariCloudFunctionException {
  PricingSignatureInvalidException(String message, {Object? details})
      : super('pricing-signature-invalid', message,
          banglaMessage: 'অর্ডারটি পরিবর্তিত হয়েছে। আবার যাচাই করুন।',
          details: details);
}

class PaymentDeclinedException extends PaykariCloudFunctionException {
  PaymentDeclinedException(String message, {String? bangla, Object? details})
      : super('payment-declined', message,
          banglaMessage: bangla ?? 'পেমেন্ট ব্যর্থ হয়েছে।',
          details: details);
}

class PermissionDeniedException extends PaykariCloudFunctionException {
  PermissionDeniedException(String message, {String? bangla, Object? details})
      : super('permission-denied', message,
          banglaMessage: bangla ?? 'এই কাজের অনুমতি নেই।',
          details: details);
}

class NotFoundException extends PaykariCloudFunctionException {
  NotFoundException(String message, {String? bangla, Object? details})
      : super('not-found', message,
          banglaMessage: bangla ?? 'তথ্য পাওয়া যায়নি।',
          details: details);
}

class InvalidArgumentException extends PaykariCloudFunctionException {
  InvalidArgumentException(String message, {String? bangla, Object? details})
      : super('invalid-argument', message,
          banglaMessage: bangla ?? 'ভুল তথ্য দেওয়া হয়েছে।',
          details: details);
}

class FailedPreconditionException extends PaykariCloudFunctionException {
  FailedPreconditionException(String message, {String? bangla, Object? details})
      : super('failed-precondition', message,
          banglaMessage: bangla ?? 'এই মুহূর্তে এই কাজটি সম্ভব নয়।',
          details: details);
}

class CloudFunctionUnavailableException extends PaykariCloudFunctionException {
  CloudFunctionUnavailableException(String message, {Object? details})
      : super('unavailable', message,
          banglaMessage: 'সার্ভারে সাময়িক সমস্যা। কিছুক্ষণ পর আবার চেষ্টা করুন।',
          details: details);
}

/// ---------------------------------------------------------------------------
/// Result models used by the wrapper. (Some are re-exported from features/.)
/// ---------------------------------------------------------------------------

class ReservationResult {
  final String reservationId;
  final DateTime expiresAt;
  const ReservationResult({required this.reservationId, required this.expiresAt});

  factory ReservationResult.fromJson(Map<String, dynamic> json) {
    return ReservationResult(
      reservationId: json['reservationId'] as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (json['expiresAt'] as num).toInt(),
      ),
    );
  }
}

class BankPaymentRequest {
  final String paymentId;
  final String status;
  final List<Map<String, dynamic>> banks;
  final int amountExpectedPoisha;
  const BankPaymentRequest({
    required this.paymentId,
    required this.status,
    required this.banks,
    required this.amountExpectedPoisha,
  });

  factory BankPaymentRequest.fromJson(Map<String, dynamic> json) {
    return BankPaymentRequest(
      paymentId: json['paymentId'] as String,
      status: json['status'] as String,
      banks: (json['banks'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
          const [],
      amountExpectedPoisha: ((json['amountExpected'] ?? 0) as num).round() * 100,
    );
  }
}

class _CallableResult {
  final dynamic data;
  const _CallableResult(this.data);
}

/// ---------------------------------------------------------------------------
/// CloudFunctionsClient — a typed singleton around FirebaseFunctions.instance
/// or a custom Express HTTP API server (Render.com / Vercel).
/// Every callable in the backend has a corresponding method here. GetIt is
/// the source of truth for the instance; register via
/// `getIt.registerSingleton<CloudFunctionsClient>(CloudFunctionsClient())`.
/// ---------------------------------------------------------------------------

class CloudFunctionsClient {
  /// Default backend API URL. If empty or null, fallback to direct Firebase Cloud Functions.
  /// Can be supplied at compile-time via `--dart-define=BACKEND_API_URL=https://...`
  /// or configured at runtime via `CloudFunctionsClient.defaultApiBaseUrl = '...'`.
  static String defaultApiBaseUrl = const String.fromEnvironment(
    'BACKEND_API_URL',
    defaultValue: 'https://paykaribazar-backend.onrender.com',
  );

  CloudFunctionsClient({
    FirebaseFunctions? functions,
    String? apiBaseUrl,
    http.Client? httpClient,
    FirebaseAuth? auth,
  })  : _functions = functions ?? FirebaseFunctions.instance,
        _apiBaseUrl = (apiBaseUrl ?? defaultApiBaseUrl).trim(),
        _http = httpClient ?? http.Client(),
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFunctions _functions;
  String _apiBaseUrl;
  final http.Client _http;
  final FirebaseAuth _auth;

  void setApiBaseUrl(String url) {
    _apiBaseUrl = url.trim().endsWith('/')
        ? url.trim().substring(0, url.trim().length - 1)
        : url.trim();
  }

  String get apiBaseUrl => _apiBaseUrl;

  /// Returns a callable bound to the backend region.
  HttpsCallable _c(String name) => _functions.httpsCallable(
        name,
        options: HttpsCallableOptions(region: _kFunctionsRegion),
      );

  // ------------------------------- pricing ---------------------------------

  Future<PricingSnapshot> calcOrder({
    required List<Map<String, dynamic>> items,
    String? addressId,
    String? couponCode,
    String? businessId,
  }) async {
    final res = await _call('calcOrder', <String, dynamic>{
      'items': items,
      if (addressId != null) 'addressId': addressId,
      if (couponCode != null) 'couponCode': couponCode,
      if (businessId != null) 'businessId': businessId,
    });
    return PricingSnapshot.fromCalcOrderResponse(res.data as Map<String, dynamic>);
  }

  // ------------------------------- inventory -------------------------------

  Future<ReservationResult> reserveStock(PricingSnapshot snap) async {
    final res = await _call('reserveStock', <String, dynamic>{
      'snapshot': snap.toJson(),
      'signature': snap.signature,
    });
    return ReservationResult.fromJson(
      Map<String, dynamic>.from(res.data as Map),
    );
  }

  Future<void> releaseReservation(
    String reservationId, {
    String reason = 'user_cancelled',
  }) async {
    await _call('releaseReservation', <String, dynamic>{
      'reservationId': reservationId,
      'reason': reason,
    });
  }

  // ------------------------------- orders ----------------------------------

  Future<String> createOrder({
    required PricingSnapshot snap,
    required String reservationId,
    String? addressId,
    required PaymentMethod paymentMethod,
    String? note,
  }) async {
    final res = await _call('createOrder', <String, dynamic>{
      'snapshot': snap.toJson(),
      'signature': snap.signature,
      'reservationId': reservationId,
      if (addressId != null) 'addressId': addressId,
      'paymentMethod': paymentMethod.wireName,
      if (note != null) 'note': note,
    });
    return (res.data as Map<String, dynamic>)['orderId'] as String;
  }

  Future<void> cancelOrder(String orderId, {required String reason}) async {
    await _call('cancelOrder', <String, dynamic>{
      'orderId': orderId,
      'reason': reason,
    });
  }

  // ------------------------------- payments --------------------------------

  Future<PaymentInit> bkashCreatePayment({
    required String orderId,
    int? amountPoisha,
  }) async {
    final res = await _call('bkashCreatePayment', <String, dynamic>{
      'orderId': orderId,
      if (amountPoisha != null) 'amountPoisha': amountPoisha,
    });
    return PaymentInit.fromJson(
      Map<String, dynamic>.from(res.data as Map),
      provider: PaymentProvider.bkash,
    );
  }

  Future<PaymentInit> nagadCreatePayment({required String orderId}) async {
    final res = await _call('nagadCreatePayment', <String, dynamic>{
      'orderId': orderId,
    });
    return PaymentInit.fromJson(
      Map<String, dynamic>.from(res.data as Map),
      provider: PaymentProvider.nagad,
    );
  }

  Future<PaymentInit> sslczCreatePayment({
    required String orderId,
    String? successUrl,
    String? failUrl,
    String? cancelUrl,
  }) async {
    final res = await _call('sslczCreatePayment', <String, dynamic>{
      'orderId': orderId,
      if (successUrl != null) 'successUrl': successUrl,
      if (failUrl != null) 'failUrl': failUrl,
      if (cancelUrl != null) 'cancelUrl': cancelUrl,
    });
    return PaymentInit.fromJson(
      Map<String, dynamic>.from(res.data as Map),
      provider: PaymentProvider.sslcommerz,
    );
  }

  Future<BankPaymentRequest> recordBankPaymentRequest({
    required String orderId,
    required String slipUrl,
    double? amountPaid,
    String? transferDate,
    String? senderAccount,
    String? note,
  }) async {
    final res = await _call('recordBankPaymentRequest', <String, dynamic>{
      'orderId': orderId,
      'slipUrl': slipUrl,
      if (amountPaid != null) 'amountPaid': amountPaid,
      if (transferDate != null) 'transferDate': transferDate,
      if (senderAccount != null) 'senderAccount': senderAccount,
      if (note != null) 'note': note,
    });
    return BankPaymentRequest.fromJson(
      Map<String, dynamic>.from(res.data as Map),
    );
  }

  Future<PaymentResult> verifyPayment({
    required PaymentProvider provider,
    required String paymentRefId,
    required String orderId,
  }) async {
    final res = await _call('verifyPayment', <String, dynamic>{
      'provider': provider.wireName,
      'paymentRefId': paymentRefId,
      'orderId': orderId,
    });
    return PaymentResult.fromJson(
      Map<String, dynamic>.from(res.data as Map),
      provider: provider,
    );
  }

  Future<void> refundPayment({
    required String paymentId,
    int? amountPoisha,
    String? reason,
  }) async {
    await _call('refundPayment', <String, dynamic>{
      'paymentId': paymentId,
      if (amountPoisha != null) 'amountPoisha': amountPoisha,
      if (reason != null) 'reason': reason,
    });
  }

  // ------------------------------- search ----------------------------------

  Future<List<Map<String, dynamic>>> searchProducts(
    String query, {
    int limit = 50,
    String? category,
    String? brand,
    int? minStock,
  }) async {
    final res = await _call('searchProducts', <String, dynamic>{
      'query': query,
      'limit': limit,
      if (category != null) 'category': category,
      if (brand != null) 'brand': brand,
      if (minStock != null) 'minStock': minStock,
    });
    final data = res.data as Map<String, dynamic>;
    final hits = data['hits'] as List<dynamic>? ?? const [];
    return hits.map((h) => Map<String, dynamic>.from(h as Map)).toList();
  }

  // ------------------------------- coupon ----------------------------------

  Future<Map<String, dynamic>> redeemCoupon({
    required String couponCode,
    required String orderId,
  }) async {
    final res = await _call('redeemCoupon', <String, dynamic>{
      'couponCode': couponCode,
      'orderId': orderId,
    });
    return Map<String, dynamic>.from(res.data as Map);
  }

  // ------------------------------- user ------------------------------------

  /// Triggers user role initialization (for Express / HTTP backends).
  Future<Map<String, dynamic>> onUserCreate({String? role}) async {
    final res = await _call('onUserCreate', <String, dynamic>{
      if (role != null) 'role': role,
    });
    return Map<String, dynamic>.from(res.data as Map);
  }

  // ------------------------------- helpers ---------------------------------

  Future<_CallableResult> _call(String name, Map<String, dynamic> args) async {
    try {
      if (_apiBaseUrl.isNotEmpty) {
        return await _callHttp(name, args);
      }
      final result = await _c(name).call(args);
      return _CallableResult(result.data);
    } on FirebaseFunctionsException catch (e) {
      throw _mapException(e);
    } on PaykariCloudFunctionException {
      rethrow;
    } catch (e) {
      // Network down, host unreachable, App Check failed, etc.
      if (kDebugMode) debugPrint('[CloudFunctionsClient] $name failed: $e');
      throw CloudFunctionUnavailableException(
        'Network error calling $name: $e',
      );
    }
  }

  Future<_CallableResult> _callHttp(String name, Map<String, dynamic> args) async {
    final baseUrl = _apiBaseUrl.endsWith('/')
        ? _apiBaseUrl.substring(0, _apiBaseUrl.length - 1)
        : _apiBaseUrl;
    final uri = Uri.parse('$baseUrl/api/$name');

    final user = _auth.currentUser;
    final token = user != null ? await user.getIdToken() : null;

    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };

    final res = await _http.post(
      uri,
      headers: headers,
      body: jsonEncode({'data': args}),
    );

    dynamic decoded;
    try {
      decoded = res.body.isNotEmpty ? jsonDecode(res.body) : null;
    } catch (_) {
      decoded = null;
    }

    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (decoded is Map) {
        if (decoded.containsKey('result')) {
          return _CallableResult(decoded['result']);
        }
        if (decoded.containsKey('data')) {
          return _CallableResult(decoded['data']);
        }
      }
      return _CallableResult(decoded);
    }

    String code = 'internal';
    String message = 'Server returned HTTP ${res.statusCode}';
    Object? details;

    if (decoded is Map && decoded['error'] is Map) {
      final err = decoded['error'] as Map;
      message = err['message']?.toString() ?? message;
      final rawStatus = err['status']?.toString().toLowerCase().replaceAll('_', '-') ?? 'internal';
      code = rawStatus;
      details = err['details'];
    } else if (res.statusCode == 401) {
      code = 'unauthenticated';
      message = 'Sign-in required.';
    } else if (res.statusCode == 403) {
      code = 'permission-denied';
      message = 'Permission denied.';
    } else if (res.statusCode == 404) {
      code = 'not-found';
      message = 'Not found.';
    }

    throw _mapCodeAndMessage(code, message, details);
  }

  PaykariCloudFunctionException _mapException(FirebaseFunctionsException e) {
    return _mapCodeAndMessage(e.code, e.message ?? '', e.details);
  }

  PaykariCloudFunctionException _mapCodeAndMessage(
    String code,
    String msg,
    Object? details,
  ) {
    switch (code) {
      case 'invalid-argument':
        return InvalidArgumentException(msg, details: details);
      case 'failed-precondition':
        // Detect stock / pricing-expired / signature sub-cases by message
        // content. The backend throws `failed-precondition` for all three
        // (see functions/src/shared/security.ts and reserveStock.ts).
        if (msg.contains('Insufficient stock') || msg.contains('stock')) {
          final productId = _extractProductId(details);
          return InsufficientStockException(msg, productId: productId);
        }
        if (msg.contains('expired') || msg.contains('Pricing snapshot has expired')) {
          return PricingExpiredException(msg);
        }
        if (msg.contains('signature') || msg.contains('tampered')) {
          return PricingSignatureInvalidException(msg);
        }
        if (msg.contains('Order does not belong to you') ||
            msg.contains('Reservation does not belong')) {
          return PermissionDeniedException(msg);
        }
        return FailedPreconditionException(msg, details: details);
      case 'not-found':
        return NotFoundException(msg, details: details);
      case 'permission-denied':
        return PermissionDeniedException(msg, details: details);
      case 'out-of-range':
        return InvalidArgumentException(msg, details: details);
      case 'unauthenticated':
        return PermissionDeniedException(msg,
            bangla: 'অনুগ্রহ করে আবার লগইন করুন।');
      case 'unavailable':
      case 'deadline-exceeded':
        return CloudFunctionUnavailableException(msg);
      case 'internal':
        return CloudFunctionUnavailableException(msg);
      default:
        return PaykariCloudFunctionException(code, msg, details: details);
    }
  }

  String? _extractProductId(Object? details) {
    if (details is Map) {
      final v = details['productId'];
      if (v is String) return v;
    }
    return null;
  }
}

/// Convenience global accessor — populated by `service_initializer.dart`.
/// Until that wiring lands, callers can construct `CloudFunctionsClient()`
/// directly.
CloudFunctionsClient? _cloudFunctionsClientSingleton;
set cloudFunctionsClientSingleton(CloudFunctionsClient? v) =>
    _cloudFunctionsClientSingleton = v;
CloudFunctionsClient get cloudFunctionsClient {
  final v = _cloudFunctionsClientSingleton;
  if (v != null) return v;
  // Lazy-init so unit tests and the existing app build still work before the
  // service_initializer wiring is updated.
  final fresh = CloudFunctionsClient();
  _cloudFunctionsClientSingleton = fresh;
  return fresh;
}
