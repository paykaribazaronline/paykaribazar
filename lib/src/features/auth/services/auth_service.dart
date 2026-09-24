import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../core/firebase/firestore_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/services/security_initializer.dart';
import '../../../di/service_locator.dart';
import '../../../core/constants/paths.dart';

final authServiceProvider = Provider((ref) {
  return getIt<AuthService>();
});

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final StorageService _storage;
  final FirestoreService _firestore;

  AuthService({
    required StorageService storage,
    required FirestoreService firestore,
  }) : _storage = storage,
       _firestore = firestore;

  String _normalizePhone(String phone) {
    String cleaned = phone.replaceAll(RegExp(r'[\s\-()]+'), '');
    if (cleaned.startsWith('+880')) {
      cleaned = cleaned.substring(4);
    } else if (cleaned.startsWith('880')) {
      cleaned = cleaned.substring(2);
    } else if (cleaned.startsWith('+88')) {
      cleaned = cleaned.substring(3);
    } else if (cleaned.startsWith('88')) {
      cleaned = cleaned.substring(2);
    }
    if (cleaned.length == 10 && RegExp(r'^[1-9]\d{9}$').hasMatch(cleaned)) {
      cleaned = '0$cleaned';
    }
    return cleaned;
  }

  String _generateReferralCode(String name, String uid) {
    final cleanName = name.replaceAll(RegExp(r'[^a-zA-Z]'), '').toUpperCase();
    final prefix = cleanName.length >= 3 ? cleanName.substring(0, 3) : 'PB';
    // Use the last 4 characters of the UID to ensure uniqueness
    final suffix = uid.substring(uid.length - 4).toUpperCase();
    return '$prefix$suffix';
  }

  Future<User?> login(String emailOrPhone, String password) async {
    try {
      String email = emailOrPhone.trim();
      // If the input doesn't look like an email, assume it's a phone number and use the internal format
      if (!email.contains('@')) {
        final normalized = _normalizePhone(email);
        email = '$normalized@paykaribazar.com';
      }

      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      if (credential.user != null) {
        await _storage.setString('user_id', credential.user!.uid);

        // Verify role via Firebase Custom Claims before trusting Firestore
        String? role;
        try {
          final idTokenResult = await credential.user!.getIdTokenResult();
          final claims = idTokenResult.claims ?? {};
          role = claims['role'] as String?;
        } catch (_) {
          role = null;
        }

        // Fallback to user doc role if custom claims missing
        try {
          final userDoc = await _db.collection(HubPaths.users).doc(credential.user!.uid).get();
          final userData = userDoc.data();
          if (!userDoc.exists || userData?['myReferralCode'] == null) {
            String name = userData?['name'] ?? 'User';
            if (!userDoc.exists) {
              // Role is provisioned via Firebase Custom Claims by the backend
              // (onUserCreate trigger or provisionStaff/setUserRole callables).
              // Email-string inference was an insecure authorization path and
              // has been removed.
              role ??= 'customer';
            }
            
            final myCode = _generateReferralCode(name, credential.user!.uid);
            await _firestore.updateProfile(credential.user!.uid, {
              if (!userDoc.exists) 'name': name,
              if (!userDoc.exists) 'email': email.contains('paykaribazar.com') && !emailOrPhone.contains('@') ? null : email,
              if (!userDoc.exists) 'phone': !emailOrPhone.contains('@') ? _normalizePhone(emailOrPhone) : null,
              if (!userDoc.exists) 'role': role,
              'myReferralCode': myCode,
              if (!userDoc.exists) 'createdAt': FieldValue.serverTimestamp(),
              if (!userDoc.exists) 'storageLimit': 50 * 1024 * 1024,
            });
          }
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Failed to auto-create/update user document: $e');
        }

        // ⭐ SECURITY: Also store token securely
        try {
          final secureAuth = SecurityInitializer.secureAuth;
          await secureAuth.storeSecureToken(
            'firebase_access_token',
            credential.user!.uid,
          );
          if (kDebugMode) debugPrint('✅ Token stored securely via SecureAuthService');
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Failed to store token securely: $e');
          // Not critical, fallback to normal storage
        }
      }
      return credential.user;
    } catch (e) {
      rethrow;
    }
  }

  Future<User?> signIn(String email, String password) async {
    return await login(email, password);
  }

  Future<UserCredential?> signUp({
    required String name,
    String? email,
    String? phone,
    required String password,
    String? referralCode,
    String? districtId,
    String? upazilaId,
    String? bloodGroup,
    bool isBloodDonor = false,
    String? bloodContactNumber,
  }) async {
    try {
      final normalizedPhone = phone != null ? _normalizePhone(phone) : null;
      final authEmail =
          email ?? (normalizedPhone != null ? '$normalizedPhone@paykaribazar.com' : null);
      if (authEmail == null) throw Exception('Email or Phone is required');

      // ১. প্রথমে ইউজার তৈরি করা (অবশ্যই আগে করতে হবে সিকিউরিটির জন্য)
      final res = await _auth.createUserWithEmailAndPassword(
        email: authEmail,
        password: password,
      );

      if (res.user != null) {
        // ২. ইউজার এখন লগইন অবস্থায় আছে, এখন প্যারালাল কাজ শুরু করা নিরাপদ
        final settingsFuture = _db.doc(HubPaths.loyaltyDoc).get();
        final myCode = _generateReferralCode(name, res.user!.uid); // Use the actual UID
        
        String? referrerUid;
        if (referralCode != null && referralCode.isNotEmpty) {
          final refDoc = await _db
              .collection(HubPaths.users)
              .where('myReferralCode', isEqualTo: referralCode)
              .limit(1)
              .get();

          if (refDoc.docs.isNotEmpty) {
            referrerUid = refDoc.docs.first.id;
          } else {
             throw Exception('Invalid referral code');
          }
        }

        // ৩. প্যারালাল টাস্কগুলোর জন্য অপেক্ষা করা
        // BUGFIX (Task ID 3-4-5-6): the original code called `Future.wait([settingsFuture])`
        // and then indexed `results[1]`, which throws a `RangeError` because
        // the array has only one element (index 0). The fix is to await the
        // single future directly.
        final settingsSnap = await settingsFuture;
        
        final signupBonus = (settingsSnap.data()?['signupPoints'] ?? 
                             settingsSnap.data()?['signup_bonus'] ?? 100).toInt();

        // ৪. ব্যাচ অপারেশন দিয়ে একবারে সব ডাটা সেভ করা (Super Fast)
        final batch = _db.batch();
        final userRef = _db.collection(HubPaths.users).doc(res.user!.uid);
        
        batch.set(userRef, {
          'name': name,
          'email': email,
          'phone': normalizedPhone,
          'referredBy': referralCode,
          'referredByUid': referrerUid,
          'myReferralCode': myCode,
          'points': signupBonus, 
          'role': 'customer',
          'districtId': districtId,
          'upazilaId': upazilaId,
          'bloodGroup': bloodGroup,
          'isBloodDonor': isBloodDonor,
          'bloodContactNumber': bloodContactNumber,
          'storageLimit': 50 * 1024 * 1024,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        // REMOVED (Task ID 3-4-5-6): the welcome-bonus ledger write to
        // `users/{uid}/transactions/{txId}`. Per the new `firestore.rules`
        // (Task ID 7-8), `transactions` is a server-only collection — client
        // writes are blocked with `allow write: if false`. The welcome
        // bonus will be credited by a backend trigger (onUserCreate already
        // provisions the `customer` role; the welcome-bonus credit is
        // deferred to a follow-up trigger or the `runSeed`-style migration).
        // Keeping the ledger server-authoritative prevents client-side
        // point-fraud.
        // final txRef = userRef.collection('transactions').doc();
        // batch.set(txRef, {
        //   'title': 'স্বাগতম বোনাস (Welcome Bonus)',
        //   'points': signupBonus,
        //   'type': 'credit',
        //   'createdAt': FieldValue.serverTimestamp(),
        // });

        if (referrerUid != null) {
          final referrerRef = _db.collection(HubPaths.users).doc(referrerUid);
          batch.update(referrerRef, {
            'referredCount': FieldValue.increment(1),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }

        if (isBloodDonor && bloodGroup != null) {
          final donorRef = _db.collection(HubPaths.donors).doc();
          batch.set(donorRef, {
            'uid': res.user!.uid,
            'name': name,
            'group': bloodGroup,
            'phone': bloodContactNumber ?? normalizedPhone,
            'districtId': districtId,
            'upazilaId': upazilaId,
            'isVisible': true,
            'lastDonated': null,
            'type': 'donor',
            'createdAt': FieldValue.serverTimestamp(),
          });
        }

        // CLEANUP PATH (Task ID 3-4-5-6): if the Firestore batch fails
        // (e.g. quota, rules, network), we delete the just-created Auth
        // user so the app doesn't end up in the "Auth user exists, Firestore
        // profile missing" inconsistent state. The user can then re-attempt
        // signup cleanly.
        try {
          await batch.commit();
        } catch (e) {
          try { await res.user?.delete(); } catch (_) {}
          rethrow;
        }
      }
      return res;
    } catch (e) {
      rethrow;
    }
  }

  Future<User?> signInWithGoogle() async {
    // TODO(prod): google_sign_in v7 removed the unnamed `GoogleSignIn()`
    // constructor, the `signIn()` instance method, and the
    // `GoogleSignInAuthentication.accessToken` getter. Migrating to the new
    // API (`GoogleSignIn.instance`, `authenticate()`, and the new
    // `serverAuthCode`-based credential flow) requires wiring up the OAuth
    // client IDs (android, iOS, web) and re-verifying the backend's
    // user-profile write — out of scope for this CI unblocking pass. Until
    // the migration lands, Google sign-in is disabled and the UI should hide
    // the "Continue with Google" button.
    debugPrint('⚠️ Google sign-in disabled — google_sign_in v7 API migration pending.');
    return null;
  }

  Future<void> registerStaff(
      {required String name,
      required String phone,
      required String staffId,
      required String password,
      required String role,
      bool allowMultipleDevices = false}) async {
    final email = '$staffId@paykaribazar.com';
    final res = await _auth.createUserWithEmailAndPassword(
        email: email, password: password);
    if (res.user != null) {
      final normalizedPhone = _normalizePhone(phone);
      final myCode = _generateReferralCode(name, res.user!.uid); // Use the actual UID
      await _firestore.updateProfile(res.user!.uid, {
        'name': name,
        'phone': normalizedPhone,
        'staffId': staffId,
        'role': role,
        'myReferralCode': myCode,
        'allowMultipleDevices': allowMultipleDevices,
        'storageLimit': 50 * 1024 * 1024,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> updateStaffCredentials(String uid, {String? phone}) async {
    if (phone != null) {
      await _firestore.updateProfile(uid, {'phone': phone});
    }
  }

  Future<void> logout() async {
    await _auth.signOut();
    await _storage.remove('user_id');
  }

  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();
}
