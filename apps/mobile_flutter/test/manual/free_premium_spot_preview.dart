// Local-only visual QA target. Never package or publish this entrypoint.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';
import 'package:mobile_flutter/features/spots/map_events.dart';
import 'package:mobile_flutter/features/spots/spots_map_page.dart';
import 'package:mobile_flutter/features/spots/spots_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ProviderScope(
      overrides: [
        surfRepositoryProvider.overrideWithValue(_MemoryRepository()),
        favoriteSpotIdsProvider.overrideWith(
          (ref) =>
              FavoriteSpotIdsNotifier(_MemoryRepository(), ref)..replaceAll({}),
        ),
        meProvider.overrideWith(
          (_) async => DemoSeed.me.copyWith(
            id: 'local-visual-qa',
            premium: false,
            emailVerified: true,
            freeLiveSpotId: 'uluwatu',
            favoriteSpotIds: [],
          ),
        ),
        spotsProvider.overrideWith((_) async => _spots),
        mapEventPostsProvider.overrideWith((_) async => []),
        emailVerificationRequiredTokenProvider.overrideWith((_) => null),
        blockedUserIdsProvider.overrideWith((_) => {}),
        followedUserIdsProvider.overrideWith((_) => {}),
        spotCardForecastProvider.overrideWith((_, _) async => null),
        spotsMapTileProviderFactory.overrideWithValue(() => _MemoryTiles()),
      ],
      child: const _Preview(),
    ),
  );
}

class _MemoryTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

class _MemoryRepository extends SurfRepository {
  _MemoryRepository() : super(_blockedDio(), DemoPersistence());
  final _favorites = <String>{};
  @override
  Future<List<String>> addFavoriteSpot(String id) async {
    _favorites.add(id);
    return _favorites.toList();
  }

  @override
  Future<List<String>> removeFavoriteSpot(String id) async {
    _favorites.remove(id);
    return _favorites.toList();
  }
}

Dio _blockedDio() => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          message: 'LOCAL VISUAL QA: network disabled.',
        ),
      ),
    ),
  );

SpotModel _spot(String id, String name, String area, double latitude) =>
    SpotModel(
      id: id,
      name: name,
      country: 'Indonesia',
      region: 'Bali',
      area: area,
      latitude: latitude,
      longitude: 115.13,
      difficulty: 'advanced',
      bestMonths: const ['May'],
      waveHeightM: 1,
      waterTempC: 26,
      imageUrl: '',
      summary: 'Local visual QA sample only.',
    );
final _spots = [
  _spot('uluwatu', 'Uluwatu Peak', 'Uluwatu', -8.82),
  _spot('echo', 'Echo Beach', 'Canggu', -8.64),
];

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  bool dark = false;
  late final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SpotsMapPage()),
      GoRoute(
        path: '/spot/:id',
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('LOCAL VISUAL QA • destination')),
          body: Center(
            child: Text('Forecast target: ${state.pathParameters['id']}'),
          ),
        ),
      ),
    ],
  );
  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    routerConfig: router,
    builder: (context, child) => Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('LOCAL VISUAL QA • offline sample only'),
                  TextButton(
                    onPressed: () => router.go('/'),
                    child: const Text('Map'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => dark = !dark),
                    child: Text(dark ? 'Light mode' : 'Dark mode'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: child!),
      ],
    ),
  );
}
