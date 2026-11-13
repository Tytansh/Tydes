import 'dart:async';

import 'package:flutter/material.dart';

class AppStartupState {
  const AppStartupState({
    required this.themeMode,
    required this.favoriteSpotIds,
  });

  final ThemeMode themeMode;
  final List<String> favoriteSpotIds;
}

/// Starts independent startup work together, but keeps every first-frame
/// prerequisite ready before the caller mounts the app.
Future<AppStartupState> prepareAppStartup({
  required bool isWeb,
  required Future<ThemeMode> Function() loadTheme,
  required Future<List<String>> Function() loadFavoriteSpotIds,
  required Future<void> Function() warmBrandLogo,
}) async {
  final (themeMode, favoriteSpotIds, _) = await (
    loadTheme(),
    // DemoPersistence uses path_provider and dart:io files, neither of which
    // supports this restoration on web. The verified account still supplies
    // its favorites when /users/me loads, as before.
    isWeb ? Future.value(const <String>[]) : loadFavoriteSpotIds(),
    isWeb ? warmBrandLogo() : Future<void>.value(),
  ).wait;

  return AppStartupState(
    themeMode: themeMode,
    favoriteSpotIds: favoriteSpotIds,
  );
}
