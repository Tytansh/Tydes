// Local-only visual QA entrypoint. Never include this target in a Site deploy.
// flutter run -d chrome -t test/manual/alert_map_preview.dart
// All app data is in memory; only the normal map tiles may use the network.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/detailed_forecast_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/alerts/alerts_page.dart';
import 'package:mobile_flutter/features/spots/spot_detail_page.dart';
import 'package:mobile_flutter/features/spots/spots_map_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer(
    overrides: [surfRepositoryProvider.overrideWithValue(_PreviewRepository())],
  );
  container.read(favoriteSpotIdsProvider.notifier).replaceAll({});
  runApp(
    UncontrolledProviderScope(container: container, child: const _Preview()),
  );
}

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  bool dark = true;
  late final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const AlertsPage()),
      GoRoute(
        path: '/spots-map',
        builder: (_, state) =>
            SpotsMapPage(initialSpotId: state.uri.queryParameters['spotId']),
      ),
      GoRoute(
        path: '/spot/:id',
        builder: (_, state) =>
            SpotDetailPage(spotId: state.pathParameters['id']!),
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
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('LOCAL VISUAL QA • sample data only'),
                  TextButton(
                    onPressed: () => router.go('/'),
                    child: const Text('Alerts'),
                  ),
                  TextButton(
                    onPressed: () => router.go('/spots-map'),
                    child: const Text('Map'),
                  ),
                  TextButton(
                    onPressed: () => router.go('/spot/uluwatu'),
                    child: const Text('Uluwatu'),
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

SpotModel _spot(
  String id,
  String name,
  String country,
  String region,
  String area,
  double lat,
  double lng,
) => SpotModel(
  id: id,
  name: name,
  country: country,
  region: region,
  area: area,
  latitude: lat,
  longitude: lng,
  difficulty: 'advanced',
  bestMonths: const ['May', 'June'],
  waveHeightM: 1,
  waterTempC: 26,
  imageUrl: '',
  summary: 'Sample surf-break guide for visual testing only.',
);

final _spots = [
  _spot(
    'uluwatu',
    'Uluwatu Peak',
    'Indonesia',
    'Bali',
    'Uluwatu',
    -8.829,
    115.084,
  ),
  _spot('echo', 'Echo Beach', 'Indonesia', 'Bali', 'Canggu', -8.65, 115.125),
  _spot(
    'broken-head',
    'Broken Head',
    'Australia',
    'New South Wales',
    'Byron Bay',
    -28.699,
    153.615,
  ),
];

AlertModel _alert(
  String id,
  String spot,
  String status, {
  bool enabled = true,
}) {
  final now = DateTime.now().toUtc();
  return AlertModel(
    id: id,
    spotId: spot,
    waveEnabled: true,
    minWaveHeightM: 1,
    windEnabled: true,
    maxWindKts: 24,
    tideEnabled: false,
    tideType: null,
    tideOffsetHours: null,
    enabled: enabled,
    status: status,
    statusReason: status == 'waiting' ? 'Waiting on wave data.' : null,
    lastEvaluatedAt: now.subtract(const Duration(minutes: 2)).toIso8601String(),
    nextCheckAt: now.add(const Duration(hours: 3)).toIso8601String(),
  );
}

Dio _blockedApi() => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          message: 'Local visual QA does not connect to any backend.',
        ),
      ),
    ),
  );

class _PreviewRepository extends SurfRepository {
  _PreviewRepository() : super(_blockedApi(), DemoPersistence());
  final _favorites = <String>{};
  final _alerts = [
    _alert('matched', 'uluwatu', 'triggered'),
    _alert('waiting', 'echo', 'waiting'),
    _alert('paused', 'broken-head', 'watching', enabled: false),
  ];

  @override
  Future<UserProfile> fetchMe() async =>
      DemoSeed.me.copyWith(id: 'visual-qa', premium: true, favoriteSpotIds: []);
  @override
  Future<List<SpotModel>> fetchSpots() async => _spots;
  @override
  Future<SpotModel> fetchSpot(String spotId) async =>
      _spots.firstWhere((s) => s.id == spotId);
  @override
  Future<List<AlertModel>> fetchAlerts() async => List.of(_alerts);
  @override
  Future<AlertModel> updateAlertEnabled({
    required String alertId,
    required bool enabled,
  }) async {
    final index = _alerts.indexWhere((a) => a.id == alertId);
    final previous = _alerts[index];
    return _alerts[index] = _alert(
      alertId,
      previous.spotId,
      previous.status,
      enabled: enabled,
    );
  }

  @override
  Future<void> deleteAlert(String alertId) async =>
      _alerts.removeWhere((a) => a.id == alertId);
  @override
  Future<List<String>> addFavoriteSpot(String spotId) async {
    _favorites.add(spotId);
    return _favorites.toList();
  }

  @override
  Future<List<String>> removeFavoriteSpot(String spotId) async {
    _favorites.remove(spotId);
    return _favorites.toList();
  }

  @override
  Future<List<ForecastModel>> fetchForecasts({
    String? spotId,
    ForecastFreshness freshness = ForecastFreshness.fresh,
  }) async => [];
  @override
  Future<DetailedForecastModel> fetchDetailedForecast(String spotId) async =>
      DetailedForecastModel.unavailable(
        spotId,
        note: 'Forecast loading is not part of this local visual fixture.',
      );
  @override
  Future<TideForecastModel> fetchTides(String spotId) async =>
      TideForecastModel.unavailable(spotId);
  @override
  Future<List<SocialPostModel>> fetchMapEvents() async => [
    SocialPostModel(
      id: 'visual-event',
      userId: 'visual-qa',
      authorName: 'TYDES Preview',
      authorHandle: 'preview',
      authorAvatarUrl: null,
      authorPremium: true,
      spotId: 'broken-head',
      postType: 'surf_plan',
      visibility: 'public',
      body: 'Sunrise surf at Broken Head',
      media: const [],
      meetupDate: DateTime.now()
          .add(const Duration(days: 1))
          .toIso8601String()
          .substring(0, 10),
      createdAt: DateTime.now().toIso8601String(),
    ),
  ];
}
