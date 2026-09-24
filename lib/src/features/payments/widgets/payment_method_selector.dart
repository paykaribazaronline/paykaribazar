import 'package:flutter/material.dart';

import '../models/payment_method.dart';

/// Cards for bKash, Nagad, Card/Bank (SSLCommerz), Bank Transfer, and COD.
/// The selected method is bubbled via [onSelected]. Each card shows the
/// English + Bangla label and a leading icon.
///
/// The widget is intentionally presentational — it does NOT call any service
/// directly. The owning screen wires the chosen [PaymentMethod] into the
/// [CheckoutRequest] before invoking `checkoutProvider.startCheckout`.
class PaymentMethodSelector extends StatelessWidget {
  const PaymentMethodSelector({
    super.key,
    required this.selected,
    required this.onSelected,
    this.enabledMethods = const [
      PaymentMethod.bkash,
      PaymentMethod.nagad,
      PaymentMethod.sslcommerz,
      PaymentMethod.bankTransfer,
      PaymentMethod.cod,
    ],
  });

  final PaymentMethod selected;
  final ValueChanged<PaymentMethod> onSelected;
  final List<PaymentMethod> enabledMethods;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final method in PaymentMethod.values)
          if (enabledMethods.contains(method))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: _PaymentCard(
                method: method,
                isSelected: method == selected,
                onTap: () => onSelected(method),
              ),
            ),
      ],
    );
  }
}

class _PaymentCard extends StatelessWidget {
  const _PaymentCard({
    required this.method,
    required this.isSelected,
    required this.onTap,
  });

  final PaymentMethod method;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.dividerColor,
              width: isSelected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(_iconData(method), size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(method.label,
                        style: theme.textTheme.titleMedium),
                    Text(method.banglaLabel,
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              Icon(
                isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.disabledColor,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconData(PaymentMethod m) {
    switch (m) {
      case PaymentMethod.bkash:
        return Icons.account_balance_wallet;
      case PaymentMethod.nagad:
        return Icons.mobile_friendly;
      case PaymentMethod.sslcommerz:
        return Icons.credit_card;
      case PaymentMethod.bankTransfer:
        return Icons.account_balance;
      case PaymentMethod.cod:
        return Icons.local_shipping;
    }
  }
}
