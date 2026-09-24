# pubspec.yaml overrides note — Task ID 3-4-5-6

**Owner:** Flutter Commerce & Payments Client Engineer
**For:** Maintainer (responsible for merging into `pubspec.yaml`)
**Do NOT modify `pubspec.yaml` directly** — another agent owns it. This note
lists the new packages the Flutter client needs now that payments /
checkout / inventory have moved to the server-authoritative Cloud Functions
backend (Task ID 9) and the deep-link payment redirect flow is in place.

## Summary

The new checkout flow opens a payment gateway URL (bKash / Nagad /
SSLCommerz) in an in-app browser and listens for a `paykaribazar://payment`
deep-link callback routed via the AndroidManifest intent-filter added in
Task ID 7-8. Two new packages are required:

- **`app_links`** — the actively-maintained deep-link subscription package
  (replaces the unmaintained `uni_links`). Used by
  `lib/src/features/payments/services/payment_redirect_handler.dart`.
- **`flutter_inappwebview`** — used by the optional
  `lib/src/features/payments/widgets/payment_web_view.dart` to open the
  gateway URL inside the app and intercept the `paykaribazar://` redirect
  directly (so we don't have to round-trip through the system browser).
  `url_launcher` is sufficient if the maintainer prefers the system
  browser path; `flutter_inappwebview` is the recommended option.

The packages already in `pubspec.yaml` are sufficient for everything else:
- `url_launcher` — fallback launcher for the gateway URL
- `dio` — HTTP client (used by legacy services)
- `firebase_auth`, `cloud_firestore`, `cloud_functions` — Firebase client SDKs
- `flutter_riverpod` — state management

## Copy-paste YAML snippet

Append to the `dependencies:` block of `pubspec.yaml`:

```yaml
dependencies:
  # ... existing deps unchanged ...

  # --- NEW: payments / checkout / deep-link (Task ID 3-4-5-6) ---
  app_links: ^6.1.1              # deep-link subscription (replaces uni_links)
  flutter_inappwebview: ^6.1.5    # in-app web view for gateway redirect
```

## Why `app_links` and not `uni_links`

`uni_links` has not seen a release since 2022 and fails on newer Android
versions. `app_links` is the community-standard replacement, supports
universal links on iOS, and is what `flutter.dev` recommends. The handler
at `lib/src/features/payments/services/payment_redirect_handler.dart`
originally had a stubbed `_appLinksStream()` method that returned
`Stream<Uri>.empty()` — the AUDIT-1 pass inlined the production
implementation directly (no separate shim file is needed because
`app_links ^6.1.1` is already in `pubspec.yaml`):

```dart
import 'package:app_links/app_links.dart';
import 'dart:async';

Stream<Uri> _appLinksStream() {
  try {
    return AppLinks().uriLinkStream;
  } catch (_) {
    return const Stream<Uri>.empty();
  }
}
```

The `CheckoutNotifier` and `PaymentNotifier` constructors wire the
handler's `onRedirect` callback to their respective state machines so
parsed deep-link params actually reach the state transitions (this wiring
was missing before the audit — even with the stream subscribed, the
parsed callback was dropped on the floor).

## Why `flutter_inappwebview`

The `url_launcher` fallback works but routes the redirect through the
system browser. On Android, when the gateway redirects to
`paykaribazar://payment?...`, the system resumes the app correctly —
*provided* the AndroidManifest intent-filter is in place (Task ID 7-8
already added it). However, debugging the redirect inside the system
browser is fragile (browser caching, redirect chains, etc.).
`flutter_inappwebview` lets the client intercept the redirect directly,
which is the production-grade approach for bKash / Nagad.

## Verification

After merging, run:

```bash
flutter pub get
flutter analyze
```

The two new packages are pure-Dart + native plugins; both ship pre-built
binaries for Android (arm64-v8a, armeabi-v7a, x86_64) and iOS, so no
additional native build steps are required.
