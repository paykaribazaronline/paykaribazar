// TODO(audit): DUPLICATE `AppStyles` class — there is a second, more
// fully-featured `AppStyles` in `lib/src/utils/styles.dart` (with the
// canonical brand teal `#008080`, dynamic config support, theme builders,
// and Bengali font wiring). This legacy class (with `#00695C`) is the
// source of an inconsistency: the only consumer is
// `lib/src/features/admin/widgets/analytics_tab.dart`, which renders
// teal-tinted cards in a slightly different shade than the rest of the
// app. The minimal migration is to update `analytics_tab.dart`'s import
// to `'../../../utils/styles.dart'` and replace `AppStyles.headingStyle` /
// `AppStyles.subheadingStyle` / `AppStyles.bodyStyle` with the canonical
// equivalents (`AppStyles.titleStyle(null, isDark:)`, etc.), then delete
// this file. Deferred because the canonical AppStyles uses different
// method signatures (functions taking a config Map vs. static getters),
// so the migration is non-trivial.

import 'package:flutter/material.dart';

class AppStyles {
  // Colors
  static const Color primaryColor = Color(0xFF00695C);
  static const Color secondaryColor = Color(0xFF004D40);
  static const Color accentColor = Color(0xFF26A69A);
  
  // Background Colors
  static Color get backgroundColor => const Color(0xFFF5F5F5);
  static Color get darkBackgroundColor => const Color(0xFF121212);
  
  // Text Styles
  static TextStyle get headingStyle => const TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.bold,
    color: primaryColor,
  );
  
  static TextStyle get subheadingStyle => const TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    color: Colors.black87,
  );
  
  static TextStyle get bodyStyle => const TextStyle(
    fontSize: 14,
    color: Colors.black87,
  );
  
  // Card Decoration
  static BoxDecoration get cardDecoration => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(12),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.1),
        blurRadius: 8,
        offset: const Offset(0, 2),
      ),
    ],
  );
  
  // Input Decoration
  static InputDecoration inputDecoration(
    String hintText,
    bool isDark, {
    Widget? prefix,
    String? hint,
  }) {
    return InputDecoration(
      hintText: hint ?? hintText,
      prefixIcon: prefix,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: isDark ? Colors.grey[700]! : Colors.grey),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: isDark ? Colors.grey[700]! : Colors.grey),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: primaryColor, width: 2),
      ),
      filled: true,
      fillColor: isDark ? const Color(0xFF1E293B) : Colors.grey.shade50,
      hintStyle: TextStyle(color: isDark ? Colors.grey[400] : Colors.grey[600]),
    );
  }
  
  // Button Style
  static ButtonStyle get primaryButtonStyle => ElevatedButton.styleFrom(
    backgroundColor: primaryColor,
    foregroundColor: Colors.white,
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
    ),
  );
  
  // Spacing
  static const double smallSpacing = 8.0;
  static const double mediumSpacing = 16.0;
  static const double largeSpacing = 24.0;
  
  // Padding
  static const EdgeInsets screenPadding = EdgeInsets.all(16.0);
  static const EdgeInsets cardPadding = EdgeInsets.all(12.0);
}
