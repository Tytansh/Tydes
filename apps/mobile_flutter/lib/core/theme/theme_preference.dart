import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_preference_store.dart';

final themePreferenceStoreProvider = Provider((ref) => ThemePreferenceStore());

/// Bootstrapped before the first frame, so a saved dark preference never
/// flashes a light Flutter screen while storage is read.
final initialThemeModeProvider = Provider((ref) => ThemeMode.system);

final themeModeProvider = StateNotifierProvider<ThemeModeController, ThemeMode>(
  (ref) => ThemeModeController(
    ref.watch(themePreferenceStoreProvider),
    ref.watch(initialThemeModeProvider),
  ),
);

ThemeMode parseThemeMode(String? value) => switch (value) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

String themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'System',
  ThemeMode.light => 'Light',
  ThemeMode.dark => 'Dark',
};

Future<ThemeMode> loadThemeMode(ThemePreferenceStore store) async {
  try {
    return parseThemeMode(await store.load());
  } catch (_) {
    // Private/blocked storage must not stop sign-in or opening the app.
    return ThemeMode.system;
  }
}

class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController(this._store, super.state);
  final ThemePreferenceStore _store;

  Future<bool> setMode(ThemeMode mode) async {
    if (mode == state) return true;
    final previous = state;
    state = mode;
    try {
      await _store.save(mode.name);
      return true;
    } catch (_) {
      if (mounted && state == mode) state = previous;
      return false;
    }
  }
}
