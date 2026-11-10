import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';
import 'package:mobile_flutter/features/spots/map_events.dart';
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

class _Repository extends SurfRepository {
  _Repository() : super(Dio(), DemoPersistence());
  int eventLoads = 0;
  bool fail = false;
  @override
  Future<List<SocialPostModel>> fetchMapEvents() async {
    eventLoads++;
    if (fail) throw StateError('Unavailable');
    return [
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
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      surfRepositoryProvider.overrideWithValue(repository),
      spotsProvider.overrideWith((_) async => _spots),
      meProvider.overrideWith((_) async => DemoSeed.me.copyWith(id: 'viewer')),
      blockedUserIdsProvider.overrideWith((_) => {'blocked'}),
      spotsMapTileProviderFactory.overrideWithValue(() => _Tiles()),
      spotCardForecastProvider.overrideWith((_, id) async {
        forecasts?.add(id);
        return null;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SpotsMapPage()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _finish(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
  await tester.pump();
}

void main() {
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

  testWidgets('saved-only filters beaches and events together', (tester) async {
    final container = await _pump(tester, _Repository());
    container.read(favoriteSpotIdsProvider.notifier).replaceAll({'batu'});
    await tester.tap(find.byKey(const ValueKey('main-map-saved-only')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('map-spot-batu')), findsOneWidget);
    expect(find.byKey(const ValueKey('map-spot-uluwatu')), findsNothing);
    expect(find.byKey(const ValueKey('map-event-marker-batu')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('map-event-marker-uluwatu')),
      findsNothing,
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
}
