import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_flutter/app/main_map_navigation.dart';
import 'package:mobile_flutter/app/router.dart' show currentTabProvider;
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/detailed_forecast_models.dart';
import 'package:mobile_flutter/core/network/public_preview_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/alerts/alert_state.dart';
import 'package:mobile_flutter/features/core/app_scaffold.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/public_previews/public_preview_page.dart';
import 'package:mobile_flutter/features/social/inbox_badges.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';
import 'package:mobile_flutter/features/spots/map_events.dart';
import 'package:mobile_flutter/features/spots/spot_detail_page.dart';
import 'package:mobile_flutter/features/spots/spots_map_page.dart';
import 'package:mobile_flutter/features/spots/spots_page.dart';

final _profile = UserProfile(
  id: 'map-navigation-viewer',
  email: 'map-navigation@example.invalid',
  displayName: 'Map Surfer',
  handle: 'map_surfer',
  bio: '',
  surfSkill: 'intermediate',
  avatarUrl: null,
  homeRegion: 'Bali',
  locale: 'en',
  premium: true,
  emailVerified: true,
  freeLiveSpotId: null,
  adsEnabled: false,
  favoriteSpotIds: const [],
);

SpotModel _spot(
  String id,
  String name,
  String country,
  String region,
  double lat,
  double lng,
) => SpotModel(
  id: id,
  name: name,
  country: country,
  region: region,
  area: name,
  latitude: lat,
  longitude: lng,
  difficulty: 'advanced',
  bestMonths: const ['May'],
  waveHeightM: 1,
  waterTempC: 25,
  imageUrl: '',
  summary: 'An offline guide for map-navigation testing.',
);

final _spots = [
  _spot('bondi', 'Bondi', 'Australia', 'New South Wales', -33.8914, 151.2767),
  _spot('uluwatu', 'Uluwatu Peak', 'Indonesia', 'Bali', -8.8184, 115.0889),
];

class _Tiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

class _EmptyAlerts extends AlertsController {
  @override
  Future<List<AlertModel>> build() async => [];
}

class _Fixture {
  _Fixture(this.container, this.router, this.apiRequests);
  final ProviderContainer container;
  final GoRouter router;
  final List<String> apiRequests;
}

Future<_Fixture> _show(
  WidgetTester tester,
  double width, {
  bool guest = false,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final apiRequests = <String>[];
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          apiRequests.add('${options.method} ${options.path}');
          handler.reject(
            DioException(
              requestOptions: options,
              message: 'Offline navigation fixture.',
            ),
          );
        },
      ),
    );
  final container = ProviderContainer(
    overrides: [
      surfRepositoryProvider.overrideWithValue(
        SurfRepository(dio, DemoPersistence()),
      ),
      meProvider.overrideWith((_) async {
        if (guest) throw StateError('Session expired');
        return _profile;
      }),
      emailVerificationRequiredTokenProvider.overrideWith((_) => null),
      spotsProvider.overrideWith((_) async => _spots),
      mapEventPostsProvider.overrideWith((_) async => []),
      spotsMapTileProviderFactory.overrideWithValue(() => _Tiles()),
      spotCardForecastProvider.overrideWith((_, _) async => null),
      spotDetailProvider.overrideWith(
        (_, id) async => _spots.firstWhere((spot) => spot.id == id),
      ),
      spotDetailedForecastProvider.overrideWith(
        (_, id) async => DetailedForecastModel.unavailable(id),
      ),
      spotTideProvider.overrideWith(
        (_, id) async => TideForecastModel.unavailable(id),
      ),
      alertsProvider.overrideWith(_EmptyAlerts.new),
      blockedUserIdsProvider.overrideWith((_) => {}),
      followedUserIdsProvider.overrideWith((_) => {}),
      socialRelationshipHydrationProvider.overrideWith((_) async {}),
      inboxUnreadCountsProvider.overrideWith(
        (_) async => InboxUnreadCounts(accountId: _profile.id),
      ),
      publicSpotPreviewProvider.overrideWith((_, id) async {
        final spot = _spots.firstWhere((spot) => spot.id == id);
        return PublicSpotPreview.fromJson({
          'id': spot.id,
          'name': spot.name,
          'country': spot.country,
          'region': spot.region,
          'area': spot.area,
          'summary': spot.summary,
          'difficulty': spot.difficulty,
          'best_months': spot.bestMonths,
        });
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(favoriteSpotIdsProvider.notifier).replaceAll({});
  if (!guest) await container.read(meProvider.future);
  final router = GoRouter(
    initialLocation: '/spot/bondi',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const AppScaffold()),
      GoRoute(
        path: '/spot/:spotId',
        builder: (_, state) =>
            SharedSpotPage(spotId: state.pathParameters['spotId']!),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) =>
            const Scaffold(body: Text('Guest sign-in destination')),
      ),
      GoRoute(
        path: '/explore',
        builder: (_, _) =>
            const Scaffold(body: Text('Guest explore destination')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return _Fixture(container, router, apiRequests);
}

MapController _expectMainMap(
  WidgetTester tester,
  _Fixture fixture,
  SpotModel spot,
) {
  expect(fixture.router.routeInformationProvider.value.uri.path, '/');
  expect(fixture.router.canPop(), isFalse);
  expect(fixture.container.read(currentTabProvider), 1);
  expect(find.byType(AppScaffold), findsOneWidget);
  // VM tests exercise native/narrow navigation even at 1440px: desktop web's
  // kIsWeb sidebar requires separate live browser QA.
  expect(find.byType(NavigationBar), findsOneWidget);
  expect(
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
    1,
  );
  expect(find.byType(BackButton), findsNothing);
  expect(find.byTooltip('Back to TYDES'), findsNothing);
  expect(find.byType(SpotsMapPage), findsOneWidget);
  expect(find.byKey(ValueKey('map-spot-${spot.id}')), findsOneWidget);
  final controller = tester
      .widget<FlutterMap>(find.byType(FlutterMap))
      .mapController!;
  expect(controller.camera.center.latitude, closeTo(spot.latitude, 0.000001));
  expect(controller.camera.center.longitude, closeTo(spot.longitude, 0.000001));
  expect(controller.camera.zoom, closeTo(9.2, 0.000001));
  expect(fixture.apiRequests, isEmpty);
  return controller;
}

void main() {
  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'forecast Map opens main Spots navigation and refocuses new and repeated targets at $width',
      (tester) async {
        final fixture = await _show(tester, width);
        expect(find.byType(SpotDetailPage), findsOneWidget);
        await tester.tap(find.byTooltip('Open on map'));
        await tester.pumpAndSettle();
        _expectMainMap(tester, fixture, _spots.first);
        final firstRequest = fixture.container.read(mainMapFocusProvider)!;
        expect(firstRequest.accountId, _profile.id);
        expect(firstRequest.spotId, 'bondi');

        // Opening a different spot must reach the retained main map, not a new
        // standalone route with its own Back navigation.
        fixture.router.push('/spot/uluwatu');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Open on map'));
        await tester.pumpAndSettle();
        final controller = _expectMainMap(tester, fixture, _spots.last);
        final secondRequest = fixture.container.read(mainMapFocusProvider)!;
        expect(secondRequest.revision, greaterThan(firstRequest.revision));

        controller.move(const LatLng(0, 0), 4);
        await tester.pumpAndSettle();
        expect(controller.camera.center.latitude, closeTo(0, 0.000001));
        // Repeating the exact same target after panning needs a fresh revision.
        fixture.router.push('/spot/uluwatu');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Open on map'));
        await tester.pumpAndSettle();
        _expectMainMap(tester, fixture, _spots.last);
        expect(
          fixture.container.read(mainMapFocusProvider)!.revision,
          greaterThan(secondRequest.revision),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'guest shared spot remains a public preview with its sign-in return path at $width',
      (tester) async {
        final fixture = await _show(tester, width, guest: true);
        expect(find.byType(SpotDetailPage), findsNothing);
        expect(find.byType(AppScaffold), findsNothing);
        expect(find.byTooltip('Open on map'), findsNothing);
        expect(fixture.container.read(mainMapFocusProvider), isNull);
        final signIn = find.text('Sign in to explore this spot');
        await tester.ensureVisible(signIn);
        await tester.tap(signIn);
        await tester.pumpAndSettle();
        final uri = fixture.router.routeInformationProvider.value.uri;
        expect(uri.path, '/login');
        expect(uri.queryParameters['next'], '/spot/bondi');
        expect(find.text('Guest sign-in destination'), findsOneWidget);
        expect(fixture.container.read(mainMapFocusProvider), isNull);
        expect(fixture.apiRequests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
