import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
// The pinned renderer exposes load state only on its internal tile widget.
// ignore: implementation_imports
import 'package:flutter_map/src/layer/tile_layer/tile.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/basic_forecast_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/detailed_forecast_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';
import 'package:mobile_flutter/features/spots/map_events.dart';
import 'package:mobile_flutter/features/spots/map_layer_switches.dart';
import 'package:mobile_flutter/features/spots/spots_map_page.dart';
import 'package:mobile_flutter/features/spots/spots_page.dart';
import 'package:mobile_flutter/features/spots/surf_map_markers.dart';

SpotModel _spot(String id, String name, String difficulty, double latitude) =>
    SpotModel(
      id: id,
      name: name,
      country: 'Indonesia',
      region: 'Bali',
      area: name,
      latitude: latitude,
      longitude: 115.13,
      difficulty: difficulty,
      bestMonths: const ['May'],
      waveHeightM: 1,
      waterTempC: 26,
      imageUrl: '',
      summary: 'A surf break.',
    );

final _spots = [
  _spot('batu', 'Batu Bolong', 'beginner', -8.65),
  _spot('uluwatu', 'Uluwatu', 'advanced', -8.82),
  _spot('echo', 'Echo Beach', 'intermediate', -8.64),
];

class _CountingSpot extends SpotModel {
  _CountingSpot(int index)
    : super(
        id: 'measured-$index',
        name: 'Measured break $index',
        country: 'Indonesia',
        region: 'Bali',
        area: 'Measured coast',
        latitude: -8.5 - index / 1000,
        longitude: 115.13,
        difficulty: 'intermediate',
        bestMonths: const ['May'],
        waveHeightM: 1,
        waterTempC: 26,
        imageUrl: '',
        summary: 'A surf break.',
      );

  int countryReads = 0;

  @override
  String get country {
    countryReads++;
    return super.country;
  }
}

SocialPostModel _event(
  String spotId, {
  String owner = 'maya',
  String visibility = 'public',
}) => SocialPostModel(
  id: 'event-$owner-$spotId',
  userId: owner,
  authorName: 'Maya Surfer',
  authorHandle: owner,
  authorAvatarUrl: null,
  authorPremium: false,
  spotId: spotId,
  postType: 'surf_plan',
  visibility: visibility,
  body: 'Sunset surf together',
  media: const [],
  meetupDate: DateTime.now()
      .add(const Duration(days: 2))
      .toIso8601String()
      .substring(0, 10),
  createdAt: DateTime.now().toIso8601String(),
);

class _Tiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

class _RecordingTiles extends _Tiles {
  final requested = <TileCoordinates>[];

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    requested.add(coordinates);
    return super.getImage(coordinates, options);
  }
}

class _Repository extends SurfRepository {
  _Repository() : super(Dio(), DemoPersistence());
  int eventLoads = 0;
  int catalogLoads = 0;
  int forecastLoads = 0;
  int selectionWrites = 0;
  int detailGuideLoads = 0;
  bool fail = false;
  List<SocialPostModel>? posts;
  @override
  Future<BasicForecastModel> fetchBasicForecast(String spotId) async {
    forecastLoads++;
    return BasicForecastModel.unavailable(spotId);
  }

  @override
  Future<DetailedForecastModel> fetchDetailedForecast(String spotId) async {
    forecastLoads++;
    return DetailedForecastModel.unavailable(spotId);
  }

  @override
  Future<TideForecastModel> fetchTides(String spotId) async {
    forecastLoads++;
    return TideForecastModel.unavailable(spotId);
  }

  @override
  Future<SpotModel> fetchSpot(String spotId) async {
    detailGuideLoads++;
    return _spots.firstWhere((spot) => spot.id == spotId);
  }

  @override
  Future<UserProfile> setFreeLiveSpot(String spotId) async {
    selectionWrites++;
    throw StateError('This shortcut must not change a selection.');
  }

  @override
  Future<List<SocialPostModel>> fetchMapEvents() async {
    eventLoads++;
    if (fail) throw StateError('Unavailable');
    return posts ??
        [
          _event('batu'),
          _event('uluwatu'),
          _event('echo', owner: 'stranger', visibility: 'followers'),
          _event('echo', owner: 'blocked'),
        ];
  }
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repository repository, {
  double width = 1440,
  List<String>? forecasts,
  String? initialSpotId,
  ThemeData? theme,
  List<SpotModel>? spots,
  UserProfile? profile,
  Future<UserProfile> Function()? loadProfile,
  String? verificationRequiredToken,
  bool withRouter = false,
  TileProvider Function()? tileProviderFactory,
  Future<List<SpotModel>> Function()? loadSpots,
  bool settle = true,
  ValueNotifier<(String?, int)>? focusRequests,
  bool embedded = false,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      surfRepositoryProvider.overrideWithValue(repository),
      spotsProvider.overrideWith((_) async {
        repository.catalogLoads++;
        return loadSpots != null ? loadSpots() : spots ?? _spots;
      }),
      meProvider.overrideWith(
        (_) async => loadProfile != null
            ? loadProfile()
            : profile ?? DemoSeed.me.copyWith(id: 'viewer'),
      ),
      emailVerificationRequiredTokenProvider.overrideWith(
        (_) => verificationRequiredToken,
      ),
      blockedUserIdsProvider.overrideWith((_) => {'blocked'}),
      spotsMapTileProviderFactory.overrideWithValue(
        tileProviderFactory ?? () => _Tiles(),
      ),
      spotCardForecastProvider.overrideWith((_, id) async {
        forecasts?.add(id);
        return null;
      }),
    ],
  );
  addTearDown(container.dispose);
  final Widget page = focusRequests == null
      ? SpotsMapPage(initialSpotId: initialSpotId, embedded: embedded)
      : ValueListenableBuilder<(String?, int)>(
          valueListenable: focusRequests,
          builder: (_, request, _) => SpotsMapPage(
            initialSpotId: request.$1,
            focusRevision: request.$2,
            embedded: embedded,
          ),
        );
  final router = withRouter
      ? GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => page),
            GoRoute(
              path: '/spot/:spotId',
              builder: (_, state) => Scaffold(
                body: Text('Routed spot ${state.pathParameters['spotId']}'),
              ),
            ),
          ],
        )
      : null;
  if (router != null) addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: router != null
          ? MaterialApp.router(theme: theme, routerConfig: router)
          : MaterialApp(theme: theme, home: page),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return container;
}

UserProfile _freeProfile({String? spotId = 'uluwatu'}) => DemoSeed.me.copyWith(
  id: 'viewer',
  premium: false,
  emailVerified: true,
  clearFreeLiveSpotId: spotId == null,
  freeLiveSpotId: spotId,
);

const _freeCard = ValueKey('free-premium-spot-card');
const _freeOpen = ValueKey('free-premium-spot-open');

Future<void> _revealFreeCard(WidgetTester tester) async {
  // A drag through the viewport's center can pan the map instead of scrolling
  // its parent. Move the outer list directly to reveal lazily built content.
  for (
    var attempt = 0;
    attempt < 20 && find.byKey(_freeCard).evaluate().isEmpty;
    attempt++
  ) {
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(
      (position.pixels + 250).clamp(0.0, position.maxScrollExtent),
    );
    await tester.pump();
  }
  expect(find.byKey(_freeCard), findsOneWidget);
  await tester.ensureVisible(find.byKey(_freeCard));
  await tester.pumpAndSettle();
}

Future<void> _finish(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
  await tester.pump();
}

void main() {
  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'retained explicit focus preserves layers and clears conflicts at $width',
      (tester) async {
        final repository = _Repository();
        final requests = ValueNotifier<(String?, int)>(('uluwatu', 1));
        addTearDown(requests.dispose);
        final forecasts = <String>[];
        final container = await _pump(
          tester,
          repository,
          width: width,
          focusRequests: requests,
          forecasts: forecasts,
          embedded: true,
        );
        final controller = tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .mapController!;
        expect(
          tester.widget<AppBar>(find.byType(AppBar)).automaticallyImplyLeading,
          isFalse,
        );
        await tester.tap(find.byKey(const ValueKey('main-map-show-events')));
        await tester.tap(find.byKey(const ValueKey('main-map-show-spots')));
        await tester.tap(find.byKey(const ValueKey('main-map-saved-only')));
        await tester.enterText(find.byType(TextField), 'no matching beach');
        await tester.pumpAndSettle();
        requests.value = ('batu', 2);
        await tester.pumpAndSettle();
        final updated = tester.widget<FlutterMap>(find.byType(FlutterMap));
        expect(updated.mapController, same(controller));
        expect(controller.camera.center, const LatLng(-8.65, 115.13));
        expect(controller.camera.zoom, 9.2);
        expect(
          tester
              .widget<Switch>(
                find.byKey(const ValueKey('main-map-show-events')),
              )
              .value,
          isFalse,
        );
        expect(
          tester
              .widget<Switch>(find.byKey(const ValueKey('main-map-show-spots')))
              .value,
          isFalse,
        );
        expect(
          tester
              .widget<Switch>(find.byKey(const ValueKey('main-map-saved-only')))
              .value,
          isFalse,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        expect(find.byType(MapEventMarker), findsNothing);
        expect(find.byType(SurfMapSpotPin), findsNothing);
        controller.move(const LatLng(-7, 116), 8.1);
        await tester.pumpAndSettle();
        requests.value = ('batu', 3);
        await tester.pumpAndSettle();
        expect(controller.camera.center, const LatLng(-8.65, 115.13));
        expect(controller.camera.zoom, 9.2);
        requests.value = ('echo', 3);
        await tester.pumpAndSettle();
        expect(controller.camera.center, const LatLng(-8.64, 115.13));
        expect(forecasts, ['uluwatu', 'batu', 'echo']);
        expect(repository.catalogLoads, 1);
        expect(repository.eventLoads, 1);
        expect(tester.takeException(), isNull);
        await _finish(tester, container);
      },
    );

    testWidgets(
      'explicit full map and latest request survive retained scroll at $width',
      (tester) async {
        final repository = _Repository();
        final requests = ValueNotifier<(String?, int)>(('uluwatu', 1));
        addTearDown(requests.dispose);
        final container = await _pump(
          tester,
          repository,
          width: width,
          focusRequests: requests,
        );
        final controller = tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .mapController!;
        final scroll = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        scroll.jumpTo(scroll.maxScrollExtent);
        await tester.pumpAndSettle();
        requests.value = ('batu', 2);
        requests.value = ('echo', 3);
        await tester.pumpAndSettle();
        expect(scroll.pixels, 0);
        expect(controller.camera.center, const LatLng(-8.64, 115.13));
        expect(controller.camera.zoom, 9.2);
        requests.value = (null, 4);
        await tester.pumpAndSettle();
        expect(find.byType(SurfMapSpotPin), findsNWidgets(_spots.length));
        expect(find.byType(MapEventMarker), findsNWidgets(2));
        expect(find.byKey(const ValueKey('main-map-full-view')), findsNothing);
        expect(controller.camera.center.latitude, closeTo(-8.73, .001));
        requests.value = ('no-longer-exists', 5);
        await tester.pumpAndSettle();
        expect(find.byType(SurfMapSpotPin), findsNWidgets(_spots.length));
        expect(repository.catalogLoads, 1);
        expect(repository.eventLoads, 1);
        expect(tester.takeException(), isNull);
        await _finish(tester, container);
      },
    );
  }

  final entrySpots = [
    DemoSeed.spots.firstWhere((spot) => spot.id == 'spot_uluwatu_peak'),
    DemoSeed.spots.firstWhere((spot) => spot.id == 'spot_bondi'),
    DemoSeed.spots.firstWhere((spot) => spot.country == 'Taiwan'),
  ];
  for (final width in [390.0, 1440.0]) {
    for (final target in entrySpots) {
      testWidgets('delayed ${target.id} entry survives resizing at $width', (
        tester,
      ) async {
        final repository = _Repository()..posts = [];
        final tiles = _RecordingTiles();
        final pending = Completer<List<SpotModel>>();
        final forecasts = <String>[];
        final container = await _pump(
          tester,
          repository,
          width: width,
          initialSpotId: target.id,
          forecasts: forecasts,
          tileProviderFactory: () => tiles,
          loadSpots: () => pending.future,
          settle: false,
        );
        expect(find.byType(FlutterMap), findsNothing);
        expect(tiles.requested, isEmpty);
        pending.complete(DemoSeed.spots);
        await tester.pumpAndSettle();
        final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
        final controller = map.mapController!;
        final center = LatLng(target.latitude, target.longitude);
        expect(map.options.initialCameraFit, isNull);
        expect(map.mapController!.camera.center, center);
        expect(map.mapController!.camera.zoom, 9.2);
        expect(find.byKey(ValueKey('map-spot-${target.id}')), findsOneWidget);
        expect(tiles.requested.every((tile) => tile.z == 9), isTrue);
        for (final nextWidth in [width == 390 ? 1440.0 : 390.0, width]) {
          tester.view.physicalSize = Size(nextWidth, 1100);
          await tester.pumpAndSettle();
          final resized = tester.widget<FlutterMap>(find.byType(FlutterMap));
          expect(resized.mapController, same(controller));
          expect(controller.camera.center, center);
          expect(controller.camera.zoom, 9.2);
          final rendered = tester.widgetList<Tile>(find.byType(Tile));
          expect(rendered, isNotEmpty);
          expect(
            rendered.every((tile) => tile.tileImage.loadStarted != null),
            isTrue,
          );
          expect(tester.takeException(), isNull);
        }
        expect(forecasts, [target.id]);
        expect(repository.catalogLoads, 1);
        expect(repository.eventLoads, 1);
        expect(repository.forecastLoads, 0);
        await _finish(tester, container);
      });
    }
  }

  testWidgets(
    'unknown entry spot retains the normal overview without fetching',
    (tester) async {
      final repository = _Repository();
      final forecasts = <String>[];
      final container = await _pump(
        tester,
        repository,
        initialSpotId: 'removed-spot',
        forecasts: forecasts,
      );
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(map.options.initialCameraFit, isNotNull);
      expect(find.byType(SurfMapSpotPin), findsNWidgets(_spots.length));
      expect(forecasts, isEmpty);
      expect(repository.catalogLoads, 1);
      expect(repository.eventLoads, 1);
      expect(tester.takeException(), isNull);
      await _finish(tester, container);
    },
  );

  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'spot entry initializes and loads the target camera at $width',
      (tester) async {
        final repository = _Repository();
        final tiles = _RecordingTiles();
        final forecasts = <String>[];
        final container = await _pump(
          tester,
          repository,
          width: width,
          forecasts: forecasts,
          initialSpotId: 'uluwatu',
          tileProviderFactory: () => tiles,
        );
        final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
        final camera = map.mapController!.camera;
        final rendered = tester.widgetList<Tile>(find.byType(Tile)).toList();
        final unloaded = rendered.where(
          (tile) => tile.tileImage.loadStarted == null,
        );
        debugPrint(
          'Spot entry $width: center=${camera.center}, zoom=${camera.zoom}, '
          'rendered=${rendered.length}, unloaded=${unloaded.length}, '
          'requested zooms=${tiles.requested.map((tile) => tile.z).toSet()}',
        );
        expect(
          unloaded,
          isEmpty,
          reason: 'Every drawn tile must start loading.',
        );
        expect(camera.center, const LatLng(-8.82, 115.13));
        expect(camera.zoom, 9.2);
        expect(map.options.initialCameraFit, isNull);
        expect(tiles.requested, isNotEmpty);
        expect(tiles.requested.every((tile) => tile.z == 9), isTrue);
        expect(forecasts, ['uluwatu']);
        expect(repository.catalogLoads, 1);
        expect(repository.eventLoads, 1);
        expect(tester.takeException(), isNull);
        await _finish(tester, container);
      },
    );
  }

  for (final width in [390.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'free Premium shortcut precedes events without forecast work at $width dark=$dark',
        (tester) async {
          const name =
              'Uluwatu Peak with a very long surf break name along the Bukit coast';
          final repository = _Repository();
          final forecasts = <String>[];
          final container = await _pump(
            tester,
            repository,
            width: width,
            profile: _freeProfile(),
            forecasts: forecasts,
            spots: [
              _spots.first,
              _spot('uluwatu', name, 'advanced', -8.82),
              _spots.last,
            ],
            theme: dark
                ? ThemeData.dark(useMaterial3: true)
                : ThemeData.light(useMaterial3: true),
          );
          await _revealFreeCard(tester);
          final card = find.byKey(_freeCard);
          expect(find.text('Your free Premium spot'), findsOneWidget);
          expect(
            find.descendant(of: card, matching: find.text(name)),
            findsOneWidget,
          );
          expect(find.byKey(_freeOpen), findsOneWidget);
          expect(find.text('View forecast'), findsOneWidget);
          expect(tester.getRect(card).left, greaterThanOrEqualTo(0));
          expect(tester.getRect(card).right, lessThanOrEqualTo(width));
          expect(
            tester.getBottomLeft(card).dy,
            lessThanOrEqualTo(
              tester.getTopLeft(find.text('2 upcoming events')).dy,
            ),
          );
          expect(forecasts, isEmpty);
          expect(repository.forecastLoads, 0);
          expect(repository.selectionWrites, 0);
          expect(repository.detailGuideLoads, 0);
          expect(repository.catalogLoads, 1);
          expect(repository.eventLoads, 1);
          expect(tester.takeException(), isNull);
          await _finish(tester, container);
        },
      );
    }

    testWidgets(
      'free shortcut survives event, saved and location filters at $width',
      (tester) async {
        final repository = _Repository();
        final forecasts = <String>[];
        final container = await _pump(
          tester,
          repository,
          width: width,
          profile: _freeProfile(),
          forecasts: forecasts,
          initialSpotId: 'batu',
        );
        expect(find.byKey(const ValueKey('map-spot-uluwatu')), findsNothing);
        await _revealFreeCard(tester);
        expect(find.text('Your free Premium spot'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(_freeCard),
            matching: find.text('Uluwatu'),
          ),
          findsOneWidget,
        );
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('main-map-show-events')));
        await tester.pumpAndSettle();
        container.read(favoriteSpotIdsProvider.notifier).replaceAll({});
        await tester.tap(find.byKey(const ValueKey('main-map-saved-only')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'no matching spot');
        await tester.pumpAndSettle();
        await _revealFreeCard(tester);
        expect(find.byKey(_freeCard), findsOneWidget);
        expect(find.byType(FlutterMap), findsOneWidget);
        expect(find.byType(SurfMapSpotPin), findsNothing);
        expect(find.byType(MapEventMarker), findsNothing);
        expect(find.textContaining('upcoming events'), findsNothing);
        expect(forecasts, ['batu']);
        expect(repository.forecastLoads, 0);
        expect(repository.selectionWrites, 0);
        expect(repository.catalogLoads, 1);
        expect(repository.eventLoads, 1);
        expect(tester.takeException(), isNull);
        await _finish(tester, container);
      },
    );
  }

  for (final entry in {
    'Premium': _freeProfile().copyWith(premium: true),
    'no selected spot': _freeProfile(spotId: null),
    'unknown selected spot': _freeProfile(spotId: 'removed-spot'),
    'empty selected spot': _freeProfile(spotId: ''),
    'unverified': _freeProfile().copyWith(emailVerified: false),
  }.entries) {
    testWidgets('free shortcut is hidden for ${entry.key}', (tester) async {
      final repository = _Repository();
      final container = await _pump(tester, repository, profile: entry.value);
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byKey(_freeCard), findsNothing);
      expect(find.byKey(_freeOpen), findsNothing);
      expect(repository.forecastLoads, 0);
      expect(repository.selectionWrites, 0);
      expect(tester.takeException(), isNull);
      await _finish(tester, container);
    });
  }

  testWidgets('verification latch hides a selected shortcut without requests', (
    tester,
  ) async {
    final repository = _Repository();
    final container = await _pump(
      tester,
      repository,
      profile: _freeProfile(),
      verificationRequiredToken: 'verification-required-fixture',
    );
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(_freeCard), findsNothing);
    expect(repository.forecastLoads, 0);
    expect(repository.selectionWrites, 0);
    await _finish(tester, container);
  });

  testWidgets('profile failure never uses the previous selected shortcut', (
    tester,
  ) async {
    final repository = _Repository();
    var failProfile = false;
    final container = await _pump(
      tester,
      repository,
      loadProfile: () async {
        if (failProfile) throw StateError('Profile unavailable');
        return _freeProfile();
      },
    );
    await _revealFreeCard(tester);
    failProfile = true;
    container.invalidate(meProvider);
    await tester.pumpAndSettle();
    expect(container.read(meProvider).hasError, isTrue);
    expect(find.byKey(_freeCard), findsNothing);
    expect(repository.forecastLoads, 0);
    expect(repository.selectionWrites, 0);
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });

  testWidgets(
    'View forecast opens the confirmed free spot, not the map selection',
    (tester) async {
      final repository = _Repository();
      final forecasts = <String>[];
      final container = await _pump(
        tester,
        repository,
        profile: _freeProfile(),
        initialSpotId: 'batu',
        forecasts: forecasts,
        withRouter: true,
      );
      await _revealFreeCard(tester);
      await tester.tap(find.byKey(_freeOpen));
      await tester.pumpAndSettle();
      expect(find.text('Routed spot uluwatu'), findsOneWidget);
      expect(find.text('Routed spot batu'), findsNothing);
      expect(forecasts, ['batu']);
      expect(repository.forecastLoads, 0);
      expect(repository.selectionWrites, 0);
      expect(repository.detailGuideLoads, 0);
      expect(tester.takeException(), isNull);
      await _finish(tester, container);
    },
  );

  testWidgets(
    'pending account replacement removes the old free spot shortcut',
    (tester) async {
      final repository = _Repository();
      Completer<UserProfile>? replacement;
      final container = await _pump(
        tester,
        repository,
        loadProfile: () => replacement?.future ?? Future.value(_freeProfile()),
        withRouter: true,
      );
      await _revealFreeCard(tester);
      expect(find.byKey(_freeCard), findsOneWidget);
      replacement = Completer<UserProfile>();
      container.invalidate(meProvider);
      expect(container.read(meProvider).isLoading, isTrue);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_freeCard), findsNothing);
      replacement.complete(
        _freeProfile(spotId: 'batu').copyWith(id: 'other-viewer'),
      );
      await tester.pumpAndSettle();
      await _revealFreeCard(tester);
      expect(
        find.descendant(
          of: find.byKey(_freeCard),
          matching: find.text('Batu Bolong'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(_freeOpen));
      await tester.pumpAndSettle();
      expect(find.text('Routed spot batu'), findsOneWidget);
      expect(repository.forecastLoads, 0);
      expect(repository.selectionWrites, 0);
      expect(tester.takeException(), isNull);
      await _finish(tester, container);
    },
  );

  testWidgets('map layer switches expose independent accessible labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var spots = true;
    var events = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, update) => MapLayerSwitches(
              showSpots: spots,
              showEvents: events,
              spotsSwitchKey: const ValueKey('spots-layer'),
              eventsSwitchKey: const ValueKey('events-layer'),
              onSpotsChanged: (value) => update(() => spots = value),
              onEventsChanged: (value) => update(() => events = value),
            ),
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Show spots'), findsOneWidget);
    expect(find.bySemanticsLabel('Show events'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('spots-layer')));
    await tester.pumpAndSettle();
    expect(spots, isFalse);
    expect(events, isTrue);
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'all layer combinations preserve camera and request counts at $width',
      (tester) async {
        final repository = _Repository();
        final forecasts = <String>[];
        final container = await _pump(
          tester,
          repository,
          width: width,
          forecasts: forecasts,
        );
        final spotsToggle = find.byKey(const ValueKey('main-map-show-spots'));
        final eventsToggle = find.byKey(const ValueKey('main-map-show-events'));
        expect(tester.widget<Switch>(spotsToggle).value, isTrue);
        expect(tester.widget<Switch>(eventsToggle).value, isTrue);
        if (width >= 980) {
          expect(
            tester.getTopLeft(spotsToggle).dy,
            tester.getTopLeft(eventsToggle).dy,
          );
          expect(
            tester.getTopLeft(spotsToggle).dx,
            lessThan(tester.getTopLeft(eventsToggle).dx),
          );
        }
        for (final toggle in [spotsToggle, eventsToggle]) {
          expect(tester.getRect(toggle).left, greaterThanOrEqualTo(0));
          expect(tester.getRect(toggle).right, lessThanOrEqualTo(width));
        }
        final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
        final mapState = tester.state(find.byType(FlutterMap));
        map.mapController!.move(const LatLng(-8.70, 115.13), 9);
        await tester.pumpAndSettle();
        final center = map.mapController!.camera.center;
        final zoom = map.mapController!.camera.zoom;
        for (final layers in [
          (false, true),
          (false, false),
          (true, false),
          (true, true),
        ]) {
          if (tester.widget<Switch>(spotsToggle).value != layers.$1) {
            await tester.tap(spotsToggle);
            await tester.pumpAndSettle();
          }
          if (tester.widget<Switch>(eventsToggle).value != layers.$2) {
            await tester.tap(eventsToggle);
            await tester.pumpAndSettle();
          }
          expect(find.byType(FlutterMap), findsOneWidget);
          expect(tester.state(find.byType(FlutterMap)), same(mapState));
          expect(find.byType(SurfMapSpotPin), findsNWidgets(layers.$1 ? 3 : 0));
          expect(find.byType(MapEventMarker), findsNWidgets(layers.$2 ? 2 : 0));
          expect(map.mapController!.camera.center, center);
          expect(map.mapController!.camera.zoom, zoom);
        }
        expect(repository.catalogLoads, 1);
        expect(repository.eventLoads, 1);
        expect(forecasts, isEmpty);
        expect(find.text('Location'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _finish(tester, container);
      },
    );

    testWidgets(
      'restoring spots respects saved-only without moving camera at $width',
      (tester) async {
        final repository = _Repository();
        final container = await _pump(tester, repository, width: width);
        container.read(favoriteSpotIdsProvider.notifier).replaceAll({'batu'});
        await tester.tap(find.byKey(const ValueKey('main-map-saved-only')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'maya');
        await tester.pumpAndSettle();
        final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
        final center = map.mapController!.camera.center;
        final zoom = map.mapController!.camera.zoom;
        final toggle = find.byKey(const ValueKey('main-map-show-spots'));
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.byType(SurfMapSpotPin), findsNothing);
        expect(find.byType(MapEventMarker), findsNWidgets(2));
        expect(find.byType(FlutterMap), findsOneWidget);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.byType(SurfMapSpotPin), findsOneWidget);
        expect(find.byKey(const ValueKey('map-spot-batu')), findsOneWidget);
        expect(find.byKey(const ValueKey('map-spot-uluwatu')), findsNothing);
        expect(
          tester
              .widget<Switch>(find.byKey(const ValueKey('main-map-saved-only')))
              .value,
          isTrue,
        );
        expect(map.mapController!.camera.center, center);
        expect(map.mapController!.camera.zoom, zoom);
        expect(repository.catalogLoads, 1);
        expect(repository.eventLoads, 1);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'maya',
        );
        expect(tester.takeException(), isNull);
        await _finish(tester, container);
      },
    );

    testWidgets(
      'hiding spots clears selected forecast but preserves location at $width',
      (tester) async {
        final repository = _Repository();
        final forecasts = <String>[];
        final container = await _pump(
          tester,
          repository,
          width: width,
          forecasts: forecasts,
          initialSpotId: 'uluwatu',
        );
        expect(forecasts, ['uluwatu']);
        final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
        final center = map.mapController!.camera.center;
        final zoom = map.mapController!.camera.zoom;
        final toggle = find.byKey(const ValueKey('main-map-show-spots'));
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.byType(SurfMapSpotPin), findsNothing);
        expect(find.text('Back to Bali'), findsOneWidget);
        expect(find.byType(MapEventMarker), findsOneWidget);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final restored = tester.widget<SurfMapSpotPin>(
          find.descendant(
            of: find.byKey(const ValueKey('map-spot-uluwatu')),
            matching: find.byType(SurfMapSpotPin),
          ),
        );
        expect(restored.size, lessThan(40));
        expect(forecasts, ['uluwatu']);
        expect(map.mapController!.camera.center, center);
        expect(map.mapController!.camera.zoom, zoom);
        expect(repository.catalogLoads, 1);
        expect(repository.eventLoads, 1);
        expect(tester.takeException(), isNull);
        await _finish(tester, container);
      },
    );
  }

  testWidgets('pinch updates camera without rebuilding the spot catalog', (
    tester,
  ) async {
    final catalog = List.generate(384, _CountingSpot.new);
    final repository = _Repository()..posts = [];
    final container = await _pump(tester, repository, spots: catalog);
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final zoom = map.mapController!.camera.zoom;
    for (final spot in catalog) {
      spot.countryReads = 0;
    }
    for (final scale in [1.02, 1.02, 0.98, 1.03]) {
      await tester.sendEventToBinding(
        PointerScaleEvent(
          position: tester.getCenter(find.byType(FlutterMap)),
          scale: scale,
        ),
      );
      await tester.pump();
    }
    final reads = catalog.fold(0, (total, spot) => total + spot.countryReads);
    debugPrint('384-spot catalog reads during four pinch updates: $reads');
    expect(map.mapController!.camera.zoom, greaterThan(zoom));
    expect(reads, 0);
    expect(find.byType(SurfMapSpotPin), findsNWidgets(384));
    expect(repository.eventLoads, 1);
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });

  testWidgets('dark map keeps search and location sheets on dark surfaces', (
    tester,
  ) async {
    final theme = ThemeData.dark(useMaterial3: true).copyWith(
      cardColor: const Color(0xFF172D32),
      scaffoldBackgroundColor: const Color(0xFF0C1C21),
    );
    final repository = _Repository();
    final container = await _pump(tester, repository, theme: theme);
    final search = tester.widget<TextField>(find.byType(TextField));
    expect(search.decoration!.fillColor, theme.cardColor);
    await tester.tap(
      find
          .ancestor(of: find.text('Location'), matching: find.byType(InkWell))
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Choose location'), findsOneWidget);
    final sheetColors = tester
        .widgetList<Container>(find.byType(Container))
        .where((widget) => widget.decoration is BoxDecoration)
        .map((widget) => (widget.decoration as BoxDecoration).color);
    expect(sheetColors, contains(theme.scaffoldBackgroundColor));
    expect(sheetColors, isNot(contains(const Color(0xFFF2F6F7))));
    expect(find.byType(SurfMapSpotPin), findsNWidgets(3));
    expect(repository.eventLoads, 1);
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });

  for (final width in [390.0, 1440.0]) {
    testWidgets('spots and event overlay coexist at width $width', (
      tester,
    ) async {
      final repository = _Repository();
      final forecasts = <String>[];
      final container = await _pump(
        tester,
        repository,
        width: width,
        forecasts: forecasts,
      );
      expect(find.text('Surf map'), findsOneWidget);
      final toggle = find.byKey(const ValueKey('main-map-show-events'));
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      expect(find.byType(MapEventMarker), findsNWidgets(2));
      expect(find.byType(SurfMapSpotPin), findsNWidgets(3));
      expect(find.byKey(const ValueKey('map-event-marker-echo')), findsNothing);
      for (final spot in _spots) {
        final pin = find.descendant(
          of: find.byKey(ValueKey('map-spot-${spot.id}')),
          matching: find.byType(SurfMapSpotPin),
        );
        expect(tester.widget<SurfMapSpotPin>(pin).difficulty, spot.difficulty);
      }
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(
        map.options.interactionOptions.flags & InteractiveFlag.scrollWheelZoom,
        0,
      );
      expect(find.byTooltip('Zoom in'), findsNothing);
      expect(find.byTooltip('Zoom out'), findsNothing);
      expect(find.byTooltip('Fit map'), findsNothing);
      final beforePinch = map.mapController!.camera.zoom;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(FlutterMap)),
          scrollDelta: const Offset(0, -40),
        ),
      );
      await tester.pumpAndSettle();
      expect(map.mapController!.camera.zoom, beforePinch);
      await tester.sendEventToBinding(
        PointerScaleEvent(
          position: tester.getCenter(find.byType(FlutterMap)),
          scale: 1.5,
        ),
      );
      await tester.pumpAndSettle();
      expect(map.mapController!.camera.zoom, greaterThan(beforePinch));
      final center = map.mapController!.camera.center;
      final zoom = map.mapController!.camera.zoom;
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byType(MapEventMarker), findsNothing);
      expect(find.byType(SurfMapSpotPin), findsNWidgets(3));
      expect(map.mapController!.camera.center, center);
      expect(map.mapController!.camera.zoom, zoom);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byType(MapEventMarker), findsNWidgets(2));
      expect(repository.eventLoads, 1);
      expect(forecasts, isEmpty);
      expect(tester.takeException(), isNull);
      await _finish(tester, container);
    });
  }

  testWidgets('saved-only filters beaches independently of events', (
    tester,
  ) async {
    final container = await _pump(tester, _Repository());
    container.read(favoriteSpotIdsProvider.notifier).replaceAll({'batu'});
    await tester.tap(find.byKey(const ValueKey('main-map-saved-only')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('map-spot-batu')), findsOneWidget);
    expect(find.byKey(const ValueKey('map-spot-uluwatu')), findsNothing);
    expect(find.byKey(const ValueKey('map-event-marker-batu')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('map-event-marker-uluwatu')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('main-map-show-events')));
    await tester.pumpAndSettle();
    expect(find.byType(SurfMapSpotPin), findsOneWidget);
    expect(
      tester
          .widget<Switch>(find.byKey(const ValueKey('main-map-saved-only')))
          .value,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });

  for (final width in [390.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'no saved beaches keeps map and independent events at $width dark=$dark',
        (tester) async {
          final repository = _Repository();
          final forecasts = <String>[];
          final container = await _pump(
            tester,
            repository,
            width: width,
            forecasts: forecasts,
            theme: dark
                ? ThemeData.dark(useMaterial3: true)
                : ThemeData.light(),
          );
          container.read(favoriteSpotIdsProvider.notifier).replaceAll({});
          final mapState = tester.state(find.byType(FlutterMap));
          final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
          final center = map.mapController!.camera.center;
          final zoom = map.mapController!.camera.zoom;
          await tester.tap(find.byKey(const ValueKey('main-map-saved-only')));
          await tester.pumpAndSettle();
          expect(find.byType(FlutterMap), findsOneWidget);
          expect(tester.state(find.byType(FlutterMap)), same(mapState));
          expect(map.mapController!.camera.center, center);
          expect(map.mapController!.camera.zoom, zoom);
          expect(find.byType(SurfMapSpotPin), findsNothing);
          expect(find.byType(MapEventMarker), findsNWidgets(2));
          expect(find.textContaining('No saved spots yet.'), findsOneWidget);
          final eventToggle = find.byKey(
            const ValueKey('main-map-show-events'),
          );
          await tester.tap(eventToggle);
          await tester.pumpAndSettle();
          expect(find.byType(FlutterMap), findsOneWidget);
          expect(find.byType(MapEventMarker), findsNothing);
          expect(find.byType(SurfMapSpotPin), findsNothing);
          await tester.tap(eventToggle);
          await tester.pumpAndSettle();
          expect(find.byType(MapEventMarker), findsNWidgets(2));
          expect(repository.eventLoads, 1);
          expect(forecasts, isEmpty);
          expect(tester.takeException(), isNull);
          await _finish(tester, container);
        },
      );
    }
  }

  testWidgets('saved-only has full location catalogue and search for events', (
    tester,
  ) async {
    final container = await _pump(tester, _Repository());
    container.read(favoriteSpotIdsProvider.notifier).replaceAll({});
    await tester.tap(find.byKey(const ValueKey('main-map-saved-only')));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .ancestor(of: find.text('Location'), matching: find.byType(InkWell))
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Indonesia').last);
    await tester.pumpAndSettle();
    expect(find.text('See all Indonesia'), findsOneWidget);
    await tester.tap(find.text('Bali').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('See all Bali'));
    await tester.pumpAndSettle();
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byType(MapEventMarker), findsNWidgets(2));
    expect(find.byType(SurfMapSpotPin), findsNothing);
    await tester.enterText(find.byType(TextField), 'Uluwatu');
    await tester.pumpAndSettle();
    expect(find.byType(MapEventMarker), findsOneWidget);
    expect(
      find.byKey(const ValueKey('map-event-marker-uluwatu')),
      findsOneWidget,
    );
    expect(find.byType(SurfMapSpotPin), findsNothing);
    await tester.enterText(find.byType(TextField), 'no matching event');
    await tester.pumpAndSettle();
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byType(MapEventMarker), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });

  testWidgets('empty catalogue still displays a usable empty map', (
    tester,
  ) async {
    final container = await _pump(tester, _Repository(), spots: []);
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byType(SurfMapSpotPin), findsNothing);
    expect(find.byType(MapEventMarker), findsNothing);
    expect(find.byKey(const ValueKey('main-map-show-events')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });

  testWidgets('host search finds event spots; beach search survives toggle', (
    tester,
  ) async {
    final container = await _pump(tester, _Repository());
    final search = find.byType(TextField);
    await tester.enterText(search, 'maya');
    await tester.pumpAndSettle();
    expect(find.byType(MapEventMarker), findsNWidgets(2));
    expect(find.byType(SurfMapSpotPin), findsNWidgets(2));
    await tester.enterText(search, 'Echo Beach');
    await tester.pumpAndSettle();
    expect(find.byType(MapEventMarker), findsNothing);
    expect(find.byKey(const ValueKey('map-spot-echo')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('main-map-show-events')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, 'Echo Beach');
    expect(find.byKey(const ValueKey('map-spot-echo')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });

  testWidgets('failed events show retry without removing the spot map', (
    tester,
  ) async {
    final repository = _Repository()..fail = true;
    final container = await _pump(tester, repository);
    expect(find.text('Could not load events'), findsOneWidget);
    expect(find.byType(SurfMapSpotPin), findsNWidgets(3));
    expect(find.textContaining('No upcoming events here'), findsNothing);
    repository.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(MapEventMarker), findsNWidgets(2));
    expect(repository.eventLoads, 2);
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });

  testWidgets('selected spot stays open when events toggle', (tester) async {
    final forecasts = <String>[];
    final container = await _pump(tester, _Repository(), forecasts: forecasts);
    await tester.tap(find.byKey(const ValueKey('main-map-show-events')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(FlutterMap));
    await tester.tap(find.byKey(const ValueKey('map-spot-uluwatu')));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(forecasts, ['uluwatu']);
    final toggle = find.byKey(const ValueKey('main-map-show-events'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final selectedPin = find.descendant(
      of: find.byKey(const ValueKey('map-spot-uluwatu')),
      matching: find.byType(SurfMapSpotPin),
    );
    expect(tester.widget<SurfMapSpotPin>(selectedPin).size, 40);
    expect(forecasts, ['uluwatu']);
    expect(tester.takeException(), isNull);
    await _finish(tester, container);
  });

  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'full map resets area and reveals own followers event at $width',
      (tester) async {
        final repository = _Repository()
          ..posts = [_event('batu', owner: 'viewer', visibility: 'followers')];
        final container = await _pump(
          tester,
          repository,
          width: width,
          initialSpotId: 'uluwatu',
        );
        expect(
          find.byKey(const ValueKey('map-event-marker-batu')),
          findsNothing,
        );
        final full = find.byKey(const ValueKey('main-map-full-view'));
        final regional = find.text('Back to Bukit / Uluwatu');
        expect(full, findsOneWidget);
        expect(regional, findsOneWidget);
        if (width > 980) {
          expect(
            tester.getTopLeft(full).dx,
            lessThan(tester.getTopLeft(regional).dx),
          );
        }
        await tester.ensureVisible(full);
        await tester.pumpAndSettle();
        await tester.tap(full);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('map-event-marker-batu')),
          findsOneWidget,
        );
        expect(find.byType(SurfMapSpotPin), findsNWidgets(3));
        expect(find.text('Back to Bali'), findsNothing);
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Switch>(
                find.byKey(const ValueKey('main-map-show-events')),
              )
              .value,
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await _finish(tester, container);
      },
    );
  }

  testWidgets('new own event refreshes while map stays mounted', (
    tester,
  ) async {
    final repository = _Repository()..posts = [];
    final container = await _pump(tester, repository);
    expect(find.byType(MapEventMarker), findsNothing);
    repository.posts = [
      _event('batu', owner: 'viewer', visibility: 'followers'),
    ];
    container.read(socialRefreshKeyProvider.notifier).state++;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('map-event-marker-batu')), findsOneWidget);
    expect(repository.eventLoads, 2);
    await _finish(tester, container);
  });

  testWidgets('own event marker paints above nearby host markers', (
    tester,
  ) async {
    final repository = _Repository()
      ..posts = [_event('batu', owner: 'viewer'), _event('uluwatu')];
    final container = await _pump(tester, repository);
    final layer = tester.widgetList<MarkerLayer>(find.byType(MarkerLayer)).last;
    final topMarker = layer.markers.last.child as MapEventMarker;
    expect(topMarker.group.spot.id, 'batu');
    expect(topMarker.viewerId, 'viewer');
    await _finish(tester, container);
  });
}
