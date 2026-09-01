import 'package:flutter/material.dart';

class AppSpacing {
  static const double xs = 4;
  static const double base = 8;
  static const double sm = 12;
  static const double gutter = 16;
  static const double md = 24;
  static const double marginMobile = 20;
  static const double lg = 40;
  static const double xl = 64;
}

class AppRadius {
  static const double sm = 4;
  static const double standard = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double full = 9999;
}

class AppTextStyles {
  static const TextStyle labelCaps = TextStyle(
    fontFamily: 'JetBrains Mono',
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 16 / 12,
    letterSpacing: 0.6,
  );

  static const TextStyle statsNumeric = TextStyle(
    fontFamily: 'JetBrains Mono',
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 24 / 18,
  );

  static const TextStyle sectionHeader = TextStyle(
    fontFamily: 'Inter',
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 24 / 18,
  );
}

class AppTheme {
  static const ColorScheme _colorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF001E40),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFF003366),
    onPrimaryContainer: Color(0xFF799DD6),
    secondary: Color(0xFF705D00),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFFCD400),
    onSecondaryContainer: Color(0xFF6E5C00),
    tertiary: Color(0xFF002413),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFF003C23),
    onTertiaryContainer: Color(0xFF1DB173),
    error: Color(0xFFBA1A1A),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFFFDAD6),
    onErrorContainer: Color(0xFF93000A),
    surface: Color(0xFFF8F9FA),
    onSurface: Color(0xFF191C1D),
    surfaceDim: Color(0xFFD9DADB),
    surfaceBright: Color(0xFFF8F9FA),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF3F4F5),
    surfaceContainer: Color(0xFFEDEEEF),
    surfaceContainerHigh: Color(0xFFE7E8E9),
    surfaceContainerHighest: Color(0xFFE1E3E4),
    onSurfaceVariant: Color(0xFF43474F),
    outline: Color(0xFF737780),
    outlineVariant: Color(0xFFC3C6D1),
    inverseSurface: Color(0xFF2E3132),
    onInverseSurface: Color(0xFFF0F1F2),
    inversePrimary: Color(0xFFA7C8FF),
    primaryFixed: Color(0xFFD5E3FF),
    primaryFixedDim: Color(0xFFA7C8FF),
    onPrimaryFixed: Color(0xFF001B3C),
    onPrimaryFixedVariant: Color(0xFF1F477B),
    secondaryFixed: Color(0xFFFFE16D),
    secondaryFixedDim: Color(0xFFE9C400),
    onSecondaryFixed: Color(0xFF221B00),
    onSecondaryFixedVariant: Color(0xFF544600),
    tertiaryFixed: Color(0xFF78FBB6),
    tertiaryFixedDim: Color(0xFF59DE9B),
    onTertiaryFixed: Color(0xFF002111),
    onTertiaryFixedVariant: Color(0xFF005232),
    surfaceTint: Color(0xFF3A5F94),
  );

  static final TextTheme _textTheme = const TextTheme(
    displayLarge: TextStyle(
      fontFamily: 'Inter',
      fontSize: 48,
      fontWeight: FontWeight.w700,
      height: 56 / 48,
      letterSpacing: -0.96,
    ),
    headlineLarge: TextStyle(
      fontFamily: 'Inter',
      fontSize: 32,
      fontWeight: FontWeight.w600,
      height: 40 / 32,
      letterSpacing: -0.32,
    ),
    titleMedium: TextStyle(
      fontFamily: 'Inter',
      fontSize: 20,
      fontWeight: FontWeight.w600,
      height: 28 / 20,
    ),
    bodyLarge: TextStyle(
      fontFamily: 'Inter',
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 24 / 16,
    ),
    bodySmall: TextStyle(
      fontFamily: 'Inter',
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 20 / 14,
    ),
    labelSmall: AppTextStyles.labelCaps,
  );

  static ThemeData get light {
    return ThemeData(
      useMaterial3: true,
      colorScheme: _colorScheme,
      scaffoldBackgroundColor: _colorScheme.surface,
      textTheme: _textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: _colorScheme.primaryContainer,
        foregroundColor: _colorScheme.onPrimary,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: _colorScheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.standard),
          side: BorderSide(color: _colorScheme.outlineVariant),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _colorScheme.primaryContainer,
          foregroundColor: _colorScheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.standard),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _colorScheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.standard),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.standard),
          borderSide: BorderSide(color: _colorScheme.primaryContainer, width: 2),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: _colorScheme.surfaceContainerLowest,
        selectedItemColor: _colorScheme.primaryContainer,
        unselectedItemColor: _colorScheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? _colorScheme.secondaryContainer
              : _colorScheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? _colorScheme.secondaryContainer.withValues(alpha: 0.5)
              : _colorScheme.surfaceContainerHigh,
        ),
      ),
    );
  }
}
