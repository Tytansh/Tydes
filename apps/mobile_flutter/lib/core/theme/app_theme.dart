import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTheme {
  static ThemeData light() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF079CA3),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF079CA3),
          secondary: const Color(0xFFF1A24B),
          surface: const Color(0xFFF6F4EE),
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF8F7F2),
      cardColor: Colors.white,
      textTheme: const TextTheme(
        headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        bodyLarge: TextStyle(fontSize: 16, height: 1.35),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: Color(0xFF142127),
        elevation: 0,
        centerTitle: false,
      ),
    );
  }

  static ThemeData dark() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF61D5CF),
          brightness: Brightness.dark,
        ).copyWith(
          primary: const Color(0xFF75DED6),
          onPrimary: const Color(0xFF073B3D),
          primaryContainer: const Color(0xFF174D50),
          onPrimaryContainer: const Color(0xFFD1F7F2),
          secondary: const Color(0xFFE9C17D),
          onSecondary: const Color(0xFF3E2D0A),
          surface: const Color(0xFF111F23),
          onSurface: const Color(0xFFE6F1EF),
          onSurfaceVariant: const Color(0xFFADC3C2),
          surfaceContainerLowest: const Color(0xFF0C171B),
          surfaceContainerLow: const Color(0xFF15272C),
          surfaceContainer: const Color(0xFF1A3035),
          surfaceContainerHigh: const Color(0xFF213B40),
          surfaceContainerHighest: const Color(0xFF2A484D),
          outline: const Color(0xFF7B9596),
          outlineVariant: const Color(0xFF345056),
        );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF0C171B),
      cardColor: const Color(0xFF15272C),
      dividerColor: scheme.outlineVariant,
      textTheme: const TextTheme(
        headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
        titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        bodyLarge: TextStyle(fontSize: 16, height: 1.35),
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFF15272C),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        modalBackgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        surfaceTintColor: Colors.transparent,
      ),
    );
  }
}
