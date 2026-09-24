import 'package:flutter_riverpod/flutter_riverpod.dart';

/// In-memory wishlist state for the customer app.
///
/// Holds the set of product IDs the current user has wishlisted. The UI in
/// `lib/src/features/wishlist/wishlist_screen.dart` reads this via
/// `ref.watch(wishlistProvider)` and renders the matching products from
/// [productsProvider]. `product_detail_screen.dart` and
/// `home_widgets.dart` toggle membership via
/// `ref.read(wishlistProvider.notifier).toggle(productId)`.
///
/// This is intentionally a local, in-memory `StateNotifierProvider<...,
/// Set<String>>` — not a `StreamProvider` backed by Firestore — so the
/// screens compile and the wishlist toggle works end-to-end on the client.
/// The Firestore-backed `WishlistService` (in
/// `services/wishlist_service.dart`) is the source of truth for cross-device
/// sync and is wired up separately by the auth bootstrap layer; this
/// provider is the UI-facing accessor for the cached `Set<String>` of
/// product IDs.
class WishlistIdsNotifier extends StateNotifier<Set<String>> {
  WishlistIdsNotifier() : super(<String>{});

  /// Adds [productId] to the wishlist if absent, or removes it if present.
  /// Always replaces `state` with a new `Set<String>` so Riverpod detects
  /// the change and notifies listeners.
  void toggle(String productId) {
    final next = Set<String>.from(state);
    if (next.contains(productId)) {
      next.remove(productId);
    } else {
      next.add(productId);
    }
    state = next;
  }

  /// Convenience helper for screens that want to test membership without
  /// going through `state.contains(...)` directly.
  bool contains(String productId) => state.contains(productId);

  /// Convenience helper for clearing the wishlist (used by logout flows).
  void clear() => state = <String>{};
}

/// The Riverpod provider that backs the wishlist UI. Re-exported from
/// `lib/src/di/providers.dart` so existing screens that import the central
/// providers file pick it up automatically.
final wishlistProvider =
    StateNotifierProvider<WishlistIdsNotifier, Set<String>>((ref) {
  return WishlistIdsNotifier();
});
