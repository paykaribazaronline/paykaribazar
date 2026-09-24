import 'package:flutter/material.dart';

import '../models/payment_result.dart';

/// Shows success / failure / pending after the gateway redirect resolves.
/// The caller passes the [PaymentResult] (or null for bank-transfer-pending
/// state) plus optional [message] for non-success cases.
class PaymentResultScreen extends StatelessWidget {
  const PaymentResultScreen({
    super.key,
    required this.success,
    this.result,
    this.message,
    this.onDone,
  });

  final bool success;
  final PaymentResult? result;
  final String? message;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('পেমেন্ট ফলাফল'),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                success ? Icons.check_circle : Icons.cancel,
                size: 72,
                color: success ? Colors.green : theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                success
                    ? 'পেমেন্ট সফল হয়েছে'
                    : (message ?? 'পেমেন্ট সফল হয়নি'),
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              if (result != null && result!.orderId.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('অর্ডার: ${result!.orderId}',
                    style: theme.textTheme.bodyMedium),
              ],
              if (result != null && result!.amountPoisha > 0) ...[
                const SizedBox(height: 4),
                Text(
                  'পরিমাণ: ৳${(result!.amountPoisha / 100).toStringAsFixed(2)}',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              if (!success && message != null) ...[
                const SizedBox(height: 8),
                Text(
                  message!,
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () {
                  if (onDone != null) {
                    onDone!.call();
                  } else {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                  }
                },
                child: const Text('ঠিক আছে'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
