import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/language_provider.dart';
import '../services/theme_provider.dart';
import '../utils/styles.dart';

class AppBarActions extends ConsumerWidget {
  const AppBarActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isEn = ref.watch(languageProvider).languageCode == 'en';
    final isDark = ref.watch(themeProvider);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Language Toggle
        GestureDetector(
          onTap: () => ref.read(languageProvider.notifier).toggleLanguage(),
          child: Container(
            width: 32, height: 32,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey[100],
              shape: BoxShape.circle,
              border: Border.all(color: isDark ? Colors.white10 : Colors.grey[300]!),
            ),
            alignment: Alignment.center,
            child: Text(
              isEn ? 'BN' : 'EN',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w900,
                color: isDark ? AppStyles.darkPrimaryColor : AppStyles.primaryColor,
              ),
            ),
          ),
        ),
        // Theme Toggle
        Container(
          width: 32, height: 32,
          margin: const EdgeInsets.only(left: 4, right: 8),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey[100],
            shape: BoxShape.circle,
            border: Border.all(color: isDark ? Colors.white10 : Colors.grey[300]!),
          ),
          child: IconButton(
            padding: EdgeInsets.zero,
            onPressed: () => ref.read(themeProvider.notifier).toggleTheme(),
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              size: 18,
              color: isDark ? Colors.amber : Colors.blueGrey,
            ),
          ),
        ),
      ],
    );
  }
}
