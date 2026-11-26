import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';

/// Lexora v2.0.0 — AMOLED-friendly Dark-first Material 3 Design System.
abstract final class LexoraTheme {
  static const Color bgDark = Color(0xFF0F131A);
  static const Color bgNavyBrand = Color(0xFF101520);
  static const Color surfaceDark = Color(0xFF171C26);
  static const Color surfaceElevatedDark = Color(0xFF1F2633);
  static const Color borderDark = Color(0xFF2D3545);

  static const Color emerald = Color(0xFF2A6F5E);
  static const Color emeraldBright = Color(0xFF3FA68D);
  static const Color sapphire = Color(0xFF3B7DD8);
  static const Color sapphireBright = Color(0xFF639EEF);
  static const Color amber = Color(0xFFD89B3C);
  static const Color violet = Color(0xFF8B6CE8);
  static const Color danger = Color(0xFFE05D5D);

  static const Color textPrimaryDark = Color(0xFFF3F6FB);
  static const Color textSecondaryDark = Color(0xFFA6B2C5);

  static Color cefrColor(String? level) {
    switch (level?.toUpperCase()) {
      case 'A1':
        return const Color(0xFF4C8C74);
      case 'A2':
        return const Color(0xFF3C8D99);
      case 'B1':
        return emeraldBright;
      case 'B2':
        return sapphireBright;
      case 'C1':
        return violet;
      case 'C2':
        return amber;
      default:
        return textSecondaryDark;
    }
  }

  static TextStyle ipaTextStyle(BuildContext context, {double fontSize = 14}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      color: isDark ? sapphireBright : sapphire,
      fontFamilyFallback: AppConstants.ipaFontFallback,
      letterSpacing: 0.2,
    );
  }

  static SystemUiOverlayStyle overlayStyleFor(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
    );
  }

  static ThemeData darkTheme() {
    const scheme = ColorScheme.dark(
      primary: sapphireBright,
      onPrimary: Color(0xFF0A1220),
      secondary: emeraldBright,
      onSecondary: Color(0xFF061A15),
      surface: surfaceDark,
      onSurface: textPrimaryDark,
      surfaceContainerHighest: surfaceElevatedDark,
      outline: borderDark,
      error: danger,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: bgDark,
      cardTheme: CardThemeData(
        color: surfaceDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: borderDark, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bgDark,
        foregroundColor: textPrimaryDark,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surfaceDark,
        indicatorColor: sapphire.withValues(alpha: 0.24),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? textPrimaryDark : textSecondaryDark,
          );
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceElevatedDark,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: borderDark),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: borderDark),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: sapphireBright, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          side: const BorderSide(color: borderDark),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceElevatedDark,
        selectedColor: sapphire.withValues(alpha: 0.28),
        side: const BorderSide(color: borderDark),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceElevatedDark,
        contentTextStyle: const TextStyle(color: textPrimaryDark),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: borderDark),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: borderDark,
        thickness: 1,
      ),
    );
  }

  static ThemeData lightTheme() {
    const scheme = ColorScheme.light(
      primary: sapphire,
      onPrimary: Colors.white,
      secondary: emerald,
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: Color(0xFF111827),
      surfaceContainerHighest: Color(0xFFEEF2F7),
      outline: Color(0xFFD5DCE8),
      error: danger,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF5F7FB),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFFDDE3EE)),
        ),
        margin: EdgeInsets.zero,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFF5F7FB),
        foregroundColor: Color(0xFF111827),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFD5DCE8)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFD5DCE8)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: sapphire, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
