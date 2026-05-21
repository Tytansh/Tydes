import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/network/demo_persistence.dart';
import 'core/network/demo_seed.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final persistedFavoriteSpotIds = await DemoPersistence()
      .loadFavoriteSpotIds();
  if (persistedFavoriteSpotIds.isNotEmpty) {
    DemoSeed.me = DemoSeed.me.copyWith(
      favoriteSpotIds: persistedFavoriteSpotIds,
    );
  }
  runApp(const ProviderScope(child: SurfTravelApp()));
}
