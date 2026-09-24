// test/firestore_rules/_placeholder_test.dart
//
// Placeholder test for the Firestore / Storage rules emulator test suite.
//
// This file exists so the `rules-emulator-test.yml` GitHub Actions workflow
// has at least one test file to run when the repo is freshly cloned. Real
// tests should be added next to this one as separate files, e.g.:
//   - test/firestore_rules/users_rules_test.dart
//   - test/firestore_rules/orders_rules_test.dart
//   - test/firestore_rules/payments_rules_test.dart
//   - test/firestore_rules/products_rules_test.dart
//   - test/firestore_rules/inventory_reservations_rules_test.dart
//   - test/firestore_rules/audit_logs_rules_test.dart
//   - test/firestore_rules/coupons_rules_test.dart
//   - test/firestore_rules/prescriptions_rules_test.dart
//
// Each test must use the `firebase_emulator` package (or fake_cloud_firestore
// with the emulator host) and assert both the ALLOWED and DENIED rules.
//
// Example test skeleton (DO NOT delete the placeholder — extend it):
//
//   test('customer cannot read another customer wallet transactions', () async {
//     final fs = FirebaseFirestore.instance;
//     await fs.collection('users').doc('alice').set({'name': 'Alice'});
//     final doc = fs.collection('users').doc('alice')
//         .collection('transactions').doc('tx1');
//     await fs.collection('users').doc('alice')
//         .collection('transactions').doc('tx1')
//         .set({'amount': 1000});
//
//     // Sign in as 'bob' (not the owner) and try to read.
//     final result = await FirebaseAuth.instance
//         .signInWithEmailAndPassword(email: 'bob@example.com', password: '...');
//     expect(
//       () => doc.get(),
//       throwsA(isA<FirebaseException>()
//           .having((e) => e.code, 'code', 'permission-denied')),
//     );
//   });

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'placeholder: rules emulator test suite is wired up',
    () {
      // TODO(maintainer): Replace this placeholder with real Firestore rules
      // tests. Each production collection (users, orders, payments,
      // inventoryReservations, auditLogs, coupons, prescriptions) needs a
      // dedicated test file that asserts:
      //   - the owner can read their own documents
      //   - other authenticated users cannot read another user's private data
      //   - client writes are denied for server-only fields (wholesalePrice,
      //     stock, reservedStock, role, isBanned, points, walletBalance)
      //   - admin/staff claim holders can perform privileged reads
      //
      // See:
      //   docs/ARCHITECTURE.md       — collection-by-collection schema
      //   docs/SECURITY.md           — trust boundary
      //   .github/workflows/rules-emulator-test.yml  — CI pipeline
      expect(true, isTrue, reason: 'placeholder assertion — replace me');
    },
  );
}
