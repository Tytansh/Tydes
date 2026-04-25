import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData light() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B6E6E),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF0B6E6E),
          secondary: const Color(0xFFF1A24B),
          surface: const Color(0xFFF6F4EE),
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF8F7F2),
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
}
