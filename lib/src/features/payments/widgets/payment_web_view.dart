import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/payment_init.dart';

/// Opens the gateway [PaymentInit.gatewayUrl] in either:
///   - an in-app web view (`flutter_inappwebview`) — preferred because it
///     lets us intercept the `paykaribazar://payment` redirect directly;
///   - or the system browser via `url_launcher` as a fallback (the
///     redirect is then routed back to the app via the AndroidManifest
///     intent-filter).
///
/// This widget is intentionally a thin shell — the deep-link parsing lives
/// in [PaymentRedirectHandler], not here. The widget's only job is to
/// launch and to surface a "Cancel" button that calls [onCancel].
///
/// The `flutter_inappwebview` package is optional until the maintainer
/// merges `pubspec_overrides_note.md`; if it is missing, we fall back to
/// `url_launcher.launchUrl(mode: LaunchMode.inAppBrowserView)`.
class PaymentWebView extends StatefulWidget {
  const PaymentWebView({
    super.key,
    required this.init,
    required this.onCancel,
    this.onLaunched,
  });

  final PaymentInit init;
  final VoidCallback onCancel;
  final VoidCallback? onLaunched;

  @override
  State<PaymentWebView> createState() => _PaymentWebViewState();
}

class _PaymentWebViewState extends State<PaymentWebView> {
  bool _launching = false;
  String? _error;

  Future<void> _launch() async {
    setState(() {
      _launching = true;
      _error = null;
    });
    final uri = Uri.tryParse(widget.init.gatewayUrl);
    if (uri == null) {
      setState(() {
        _launching = false;
        _error = 'Invalid gateway URL';
      });
      return;
    }
    try {
      // Preferred: in-app browser view (uses Chrome Custom Tabs / SFSafariViewController).
      final ok = await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
        webOnlyWindowName: '_self',
      );
      if (!ok) {
        // Try external browser as a fallback.
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      widget.onLaunched?.call();
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _launching = false);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Auto-launch when the widget is first shown.
    if (!_launching && _error == null) {
      _launch();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('পেমেন্ট'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: widget.onCancel,
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_launching) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('পেমেন্ট পেজ খোলা হচ্ছে…',
                    style: theme.textTheme.bodyLarge),
              ] else if (_error != null) ...[
                Icon(Icons.error_outline,
                    size: 48, color: theme.colorScheme.error),
                const SizedBox(height: 8),
                Text(_error!, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _launch,
                  child: const Text('আবার চেষ্টা করুন'),
                ),
              ] else ...[
                const Icon(Icons.open_in_browser, size: 48),
                const SizedBox(height: 8),
                Text('পেমেন্ট সম্পন্ন হলে এখানে ফিরে আসবে',
                    style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 32),
              OutlinedButton(
                onPressed: widget.onCancel,
                child: const Text('বাতিল করুন'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
