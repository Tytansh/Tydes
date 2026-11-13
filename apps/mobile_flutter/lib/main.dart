import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/network/demo_persistence.dart';
import 'core/network/demo_seed.dart';
import 'core/startup/app_startup.dart';
import 'core/theme/theme_preference.dart';
import 'core/theme/theme_preference_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final startup = await prepareAppStartup(
    isWeb: kIsWeb,
    loadTheme: () => loadThemeMode(ThemePreferenceStore()),
    loadFavoriteSpotIds: DemoPersistence().loadFavoriteSpotIds,
    warmBrandLogo: _warmBrandLogo,
  );
  if (startup.favoriteSpotIds.isNotEmpty) {
    DemoSeed.me = DemoSeed.me.copyWith(
      favoriteSpotIds: startup.favoriteSpotIds,
    );
  }
  runApp(
    ProviderScope(
      overrides: [
        initialThemeModeProvider.overrideWithValue(startup.themeMode),
      ],
      child: const SurfTravelApp(),
    ),
  );
}

Future<void> _warmBrandLogo() async {
  const provider = AssetImage('assets/branding/tydes-wave-blue-256.png');
  final stream = provider.resolve(ImageConfiguration.empty);
  final ready = Completer<void>();
  late final ImageStreamListener listener;

  void finish() {
    if (!ready.isCompleted) ready.complete();
    stream.removeListener(listener);
  }

  listener = ImageStreamListener(
    (_, _) => finish(),
    onError: (_, _) => finish(),
  );
  stream.addListener(listener);
  await ready.future.timeout(
    const Duration(seconds: 2),
    onTimeout: () {
      stream.removeListener(listener);
    },
  );
}
