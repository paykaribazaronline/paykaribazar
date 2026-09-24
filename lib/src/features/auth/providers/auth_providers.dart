import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/auth_service.dart';
import '../../../core/firebase/firestore_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/constants/paths.dart';
import '../../../services/role_simulator_provider.dart'; // Assuming this is a general service
import '../../../di/service_locator.dart';

// --- AUTH PROVIDERS ---

// Firebase Auth instance provider
final firebaseAuthProvider = Provider((ref) => FirebaseAuth.instance);

// Firebase Firestore instance provider (if not already in a core provider file)
final firebaseFirestoreInstanceProvider = Provider((ref) => FirebaseFirestore.instance);

// Storage Service Provider
final storageServiceProvider = Provider<StorageService>((ref) => getIt<StorageService>());

// Firestore Service Provider
final firestoreServiceProvider = Provider<FirestoreService>((ref) => getIt<FirestoreService>());

// AuthService Provider
final authServiceProvider = Provider<AuthService>((ref) => getIt<AuthService>());

final authProvider = authServiceProvider; // Alias for convenience

final authStateProvider = StreamProvider<User?>((ref) => ref.watch(firebaseAuthProvider).authStateChanges());

/// Currently active user ID (with simulation support)
/// This ensures both reads and writes operate on the simulated user.
final activeUserIdProvider = Provider<String?>((ref) {
  // Logic check: If user is logged out, simulation MUST be null
  ref.listen<AsyncValue<User?>>(authStateProvider, (previous, next) {
    if (next.value == null) {
      ref.read(simulatedUserUidProvider.notifier).state = null;
    }
  });

  final authUser = ref.watch(authStateProvider).value;
  if (authUser == null) {
    return null;
  }

  final simulatedUid = ref.watch(simulatedUserUidProvider);
  if (simulatedUid != null) return simulatedUid;
  return authUser.uid;
});

/// User data stream - automatically handles simulation
final currentUserDataProvider = StreamProvider<Map<String, dynamic>?>((ref) {
  final uid = ref.watch(activeUserIdProvider);
  final authState = ref.watch(authStateProvider);
  if (authState.value == null || uid == null) return Stream.value(null);

  return ref.watch(firebaseFirestoreInstanceProvider)
      .collection(HubPaths.users)
      .doc(uid)
      .snapshots()
      .map((snap) {
        final data = snap.data();
        if (data == null) return null;
        return {'id': snap.id, ...data};
      });
});

final actualUserDataProvider = currentUserDataProvider; // Alias

final authUserDataProvider = StreamProvider<Map<String, dynamic>?>((ref) {
  final user = ref.watch(authStateProvider).value;
  if (user == null) return Stream.value(null);
  return ref.watch(firebaseFirestoreInstanceProvider).collection(HubPaths.users).doc(user.uid).snapshots().map((snap) {
    final data = snap.data();
    if (data == null) return null;
    return {'id': snap.id, ...data};
  });
});

final allUsersProvider = StreamProvider<List<Map<String, dynamic>>>((ref) {
  final user = ref.watch(authStateProvider).value;
  if (user == null) return Stream.value(<Map<String, dynamic>>[]);
  final userData = ref.watch(currentUserDataProvider).value;
  final role = userData?['role'] ?? 'customer';
  if (role != 'admin' && role != 'staff') return Stream.value(<Map<String, dynamic>>[]);
  return ref.watch(firebaseFirestoreInstanceProvider).collection(HubPaths.users).snapshots().map((snap) => snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList());
});