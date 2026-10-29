import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/network/demo_persistence.dart';
import 'core/network/demo_seed.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    await _warmBrandLogo();
  }
  final persistedFavoriteSpotIds = await DemoPersistence()
      .loadFavoriteSpotIds();
  if (persistedFavoriteSpotIds.isNotEmpty) {
    DemoSeed.me = DemoSeed.me.copyWith(
      favoriteSpotIds: persistedFavoriteSpotIds,
    );
  }
  runApp(const ProviderScope(child: SurfTravelApp()));
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
