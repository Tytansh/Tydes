import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/public_preview_models.dart';
import 'package:mobile_flutter/features/guest/guest_explore_page.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/spots/map_events.dart';
import 'package:mobile_flutter/features/spots/map_pinch_gestures.dart';
import 'package:mobile_flutter/features/spots/spots_map_page.dart';
import 'package:mobile_flutter/features/spots/spots_page.dart';

class _Tiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

const _spotData = {
  'id': 'test-break',
  'name': 'Test Break',
  'country': 'Indonesia',
  'region': 'Bali',
  'area': 'Bukit',
  'summary': 'A surf break.',
  'difficulty': 'intermediate',
  'best_months': ['May'],
  'latitude': -8.6,
  'longitude': 115.1,
};

Future<({MapController map, ScrollController page})> _show(
  WidgetTester tester, {
  double rotation = 0,
}) async {
  final map = MapController();
  final page = ScrollController();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          controller: page,
          children: [
            const SizedBox(height: 83),
            Padding(
              padding: const EdgeInsets.only(left: 77, right: 29),
              child: SizedBox(
                height: 360,
                child: SurfMapPinchGestures(
                  controller: map,
                  child: FlutterMap(
                    mapController: map,
                    options: MapOptions(
                      initialCenter: const LatLng(-8.6, 115.1),
                      initialZoom: 5,
                      initialRotation: rotation,
                      minZoom: 2,
                      maxZoom: 14,
                      interactionOptions: surfMapInteractionOptions,
                    ),
                    children: const [ColoredBox(color: Colors.blue)],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 1400),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (map: map, page: page);
}

Future<void> _finish(
  WidgetTester tester,
  ({MapController map, ScrollController page}) controllers,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controllers.map.dispose();
  controllers.page.dispose();
  await tester.pump();
}

void main() {
  test('only wheel zoom is removed from existing interactions', () {
    expect(
      surfMapInteractionOptions.flags,
      InteractiveFlag.all & ~InteractiveFlag.scrollWheelZoom,
    );
    expect(
      InteractiveFlag.hasPinchZoom(surfMapInteractionOptions.flags),
      isTrue,
    );
    expect(InteractiveFlag.hasDrag(surfMapInteractionOptions.flags), isTrue);
  });

  testWidgets('ordinary wheel scroll moves the page, never the map', (
    tester,
  ) async {
    final controllers = await _show(tester);
    final camera = controllers.map.camera;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(FlutterMap)),
        scrollDelta: const Offset(0, 120),
      ),
    );
    await tester.pumpAndSettle();
    expect(controllers.page.offset, greaterThan(0));
    expect(controllers.map.camera.zoom, camera.zoom);
    expect(controllers.map.camera.center, camera.center);
    expect(tester.takeException(), isNull);
    await _finish(tester, controllers);
  });

  testWidgets(
    'trackpad translation pans immediately without a preceding pinch',
    (tester) async {
      final controllers = await _show(tester);
      final before = controllers.map.camera;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.trackpad,
          position: tester.getCenter(find.byType(FlutterMap)),
          scrollDelta: const Offset(-36, 54),
        ),
      );
      await tester.pump();
      expect(controllers.map.camera.center, isNot(before.center));
      expect(controllers.map.camera.zoom, before.zoom);
      expect(controllers.page.offset, 0);
      expect(tester.takeException(), isNull);
      await _finish(tester, controllers);
    },
  );

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.unknown]) {
    testWidgets('$kind scroll remains page scroll even after browser zoom', (
      tester,
    ) async {
      final controllers = await _show(tester);
      final position = tester.getCenter(find.byType(FlutterMap));
      await tester.sendEventToBinding(
        PointerScaleEvent(
          kind: PointerDeviceKind.trackpad,
          position: position,
          scale: 1.5,
        ),
      );
      await tester.pump();
      final before = controllers.map.camera;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: kind,
          position: position,
          scrollDelta: const Offset(0, 120),
        ),
      );
      await tester.pumpAndSettle();
      expect(controllers.page.offset, greaterThan(0));
      expect(controllers.map.camera.center, before.center);
      expect(controllers.map.camera.zoom, before.zoom);
      expect(tester.takeException(), isNull);
      await _finish(tester, controllers);
    });
  }

  for (final rotation in [0.0, 37.0]) {
    testWidgets('browser pinch keeps cursor anchored at rotation $rotation', (
      tester,
    ) async {
      final controllers = await _show(tester, rotation: rotation);
      final mapRect = tester.getRect(find.byType(FlutterMap));
      final position = mapRect.center + const Offset(79, -46);
      final localPosition = position - mapRect.topLeft;
      final anchoredPoint = controllers.map.camera.screenOffsetToLatLng(
        localPosition,
      );
      for (final scale in [1.2, 1.2]) {
        await tester.sendEventToBinding(
          PointerScaleEvent(position: position, scale: scale),
        );
        await tester.pump();
      }
      expect(
        controllers.map.camera.zoom,
        closeTo(5 + math.log(1.44) / math.ln2, 1e-9),
      );
      final after = controllers.map.camera.screenOffsetToLatLng(localPosition);
      expect(after.latitude, closeTo(anchoredPoint.latitude, 1e-8));
      expect(after.longitude, closeTo(anchoredPoint.longitude, 1e-8));
      await tester.sendEventToBinding(
        PointerScaleEvent(position: position, scale: 1 / 1.44),
      );
      await tester.pump();
      expect(controllers.map.camera.zoom, closeTo(5, 1e-9));
      expect(controllers.page.offset, 0);
      expect(tester.takeException(), isNull);
      await _finish(tester, controllers);
    });
  }

  testWidgets('invalid and neutral scales are ignored, valid scales clamp', (
    tester,
  ) async {
    final controllers = await _show(tester);
    final position = tester.getCenter(find.byType(FlutterMap));
    final camera = controllers.map.camera;
    for (final scale in [
      0.0,
      -1.0,
      double.nan,
      double.infinity,
      -double.infinity,
      1.0,
    ]) {
      await tester.sendEventToBinding(
        PointerScaleEvent(position: position, scale: scale),
      );
      await tester.pump();
      expect(controllers.map.camera.zoom, camera.zoom);
      expect(controllers.map.camera.center, camera.center);
    }
    for (final (scale, expected) in [
      (1e20, 14.0),
      (1e20, 14.0),
      (1e-20, 2.0),
      (1e-20, 2.0),
    ]) {
      await tester.sendEventToBinding(
        PointerScaleEvent(position: position, scale: scale),
      );
      await tester.pump();
      expect(controllers.map.camera.zoom, expected);
    }
    expect(tester.takeException(), isNull);
    await _finish(tester, controllers);
  });

  testWidgets('native trackpad PanZoom still uses the map recognizer once', (
    tester,
  ) async {
    final controllers = await _show(tester);
    final position = tester.getCenter(find.byType(FlutterMap));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(position);
    await gesture.panZoomUpdate(position, scale: 1.2);
    await tester.pump();
    await gesture.panZoomUpdate(position, scale: 1.5);
    await tester.pump();
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();
    expect(
      controllers.map.camera.zoom,
      closeTo(5 + math.log(1.5) / math.ln2, 1e-6),
    );
    expect(tester.takeException(), isNull);
    await _finish(tester, controllers);
  });

  testWidgets('touch fingers can translate together after pinching to zoom', (
    tester,
  ) async {
    final controllers = await _show(tester);
    final position = tester.getCenter(find.byType(FlutterMap));
    final left = await tester.startGesture(
      position - const Offset(40, 0),
      pointer: 1,
    );
    final right = await tester.startGesture(
      position + const Offset(40, 0),
      pointer: 2,
    );
    await left.moveBy(const Offset(-20, 0));
    await right.moveBy(const Offset(20, 0));
    await tester.pump();
    await left.moveBy(const Offset(-35, 0));
    await right.moveBy(const Offset(35, 0));
    await tester.pump();
    final beforePan = controllers.map.camera;
    for (var index = 0; index < 3; index++) {
      await left.moveBy(const Offset(20, 15));
      await right.moveBy(const Offset(20, 15));
      await tester.pump();
    }
    expect(controllers.map.camera.center, isNot(beforePan.center));
    expect(controllers.map.camera.zoom, closeTo(beforePan.zoom, 1e-6));
    expect(controllers.page.offset, 0);
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _finish(tester, controllers);
  });

  testWidgets('native trackpad translates at fixed scale after pinch', (
    tester,
  ) async {
    final controllers = await _show(tester);
    final position = tester.getCenter(find.byType(FlutterMap));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(position);
    await gesture.panZoomUpdate(position, scale: 1.2);
    await tester.pump();
    await gesture.panZoomUpdate(position, scale: 1.5);
    await tester.pump();
    final beforePan = controllers.map.camera;
    for (final pan in [
      const Offset(20, 15),
      const Offset(40, 30),
      const Offset(60, 45),
    ]) {
      await gesture.panZoomUpdate(position, scale: 1.5, pan: pan);
      await tester.pump();
    }
    expect(controllers.map.camera.center, isNot(beforePan.center));
    expect(controllers.map.camera.zoom, closeTo(beforePan.zoom, 1e-6));
    expect(controllers.page.offset, 0);
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _finish(tester, controllers);
  });

  testWidgets('native trackpad can scale and translate in the same update', (
    tester,
  ) async {
    final controllers = await _show(tester);
    final position = tester.getCenter(find.byType(FlutterMap));
    final before = controllers.map.camera;
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(position);
    await gesture.panZoomUpdate(
      position,
      scale: 1.2,
      pan: const Offset(20, 15),
    );
    await tester.pump();
    await gesture.panZoomUpdate(
      position,
      scale: 1.5,
      pan: const Offset(40, 30),
    );
    await tester.pump();
    expect(controllers.map.camera.center, isNot(before.center));
    expect(
      controllers.map.camera.zoom,
      closeTo(5 + math.log(1.5) / math.ln2, 1e-6),
    );
    expect(controllers.page.offset, 0);
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _finish(tester, controllers);
  });

  for (final rotation in [0.0, 37.0]) {
    testWidgets(
      'browser pinch then trackpad pan follows both axes at $rotation',
      (tester) async {
        final controllers = await _show(tester, rotation: rotation);
        final mapRect = tester.getRect(find.byType(FlutterMap));
        final position = mapRect.center + const Offset(79, -46);
        await tester.sendEventToBinding(
          PointerScaleEvent(
            kind: PointerDeviceKind.trackpad,
            device: 7,
            position: position,
            scale: 1.5,
          ),
        );
        await tester.pump();
        final beforePan = controllers.map.camera;
        final local = position - mapRect.topLeft;
        final anchor = beforePan.screenOffsetToLatLng(local);
        var cumulativeDelta = Offset.zero;
        for (final delta in [
          const Offset(48, -31),
          const Offset(-25, 60),
          const Offset(-31, -8),
          const Offset(12, 19),
        ]) {
          await tester.sendEventToBinding(
            PointerScrollEvent(
              kind: PointerDeviceKind.trackpad,
              device: 7,
              position: position,
              scrollDelta: delta,
            ),
          );
          await tester.pump();
          cumulativeDelta += delta;
          final afterPan = controllers.map.camera;
          expect(afterPan.center, isNot(beforePan.center));
          expect(afterPan.zoom, closeTo(beforePan.zoom, 1e-9));
          final moved = afterPan.screenOffsetToLatLng(local - cumulativeDelta);
          expect(moved.latitude, closeTo(anchor.latitude, 1e-8));
          expect(moved.longitude, closeTo(anchor.longitude, 1e-8));
        }
        expect(controllers.page.offset, 0);
        expect(tester.takeException(), isNull);
        await _finish(tester, controllers);
      },
    );
  }

  testWidgets('touchscreen pinch and mouse drag remain enabled', (
    tester,
  ) async {
    final controllers = await _show(tester);
    final position = tester.getCenter(find.byType(FlutterMap));
    final left = await tester.startGesture(
      position - const Offset(40, 0),
      pointer: 1,
    );
    final right = await tester.startGesture(
      position + const Offset(40, 0),
      pointer: 2,
    );
    await left.moveBy(const Offset(-20, 0));
    await right.moveBy(const Offset(20, 0));
    await tester.pump();
    await left.moveBy(const Offset(-35, 0));
    await right.moveBy(const Offset(35, 0));
    await tester.pump();
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(controllers.map.camera.zoom, greaterThan(5));
    final center = controllers.map.camera.center;
    await tester.dragFrom(
      position,
      const Offset(60, 25),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(controllers.map.camera.center, isNot(center));
    expect(tester.takeException(), isNull);
    await _finish(tester, controllers);
  });

  for (final zoom in [2.0, 14.0]) {
    testWidgets('two-finger pan remains available at zoom bound $zoom', (
      tester,
    ) async {
      final controllers = await _show(tester);
      controllers.map.move(controllers.map.camera.center, zoom);
      await tester.pump();
      final before = controllers.map.camera;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.trackpad,
          position: tester.getCenter(find.byType(FlutterMap)),
          scrollDelta: const Offset(40, 25),
        ),
      );
      await tester.pump();
      expect(controllers.map.camera.center, isNot(before.center));
      expect(controllers.map.camera.zoom, zoom);
      expect(controllers.page.offset, 0);
      await _finish(tester, controllers);
    });
  }

  for (final guest in [false, true]) {
    testWidgets(
      '${guest ? 'guest' : 'main'} map shares pinch and pan without refetching',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1440, 1100);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        var spotsCalls = 0, eventsCalls = 0, profileCalls = 0;
        final container = ProviderContainer(
          overrides: [
            meProvider.overrideWith((_) async {
              profileCalls++;
              return DemoSeed.me;
            }),
            spotsProvider.overrideWith((_) async {
              spotsCalls++;
              return [
                SpotModel(
                  id: 'test-break',
                  name: 'Test Break',
                  country: 'Indonesia',
                  region: 'Bali',
                  area: 'Bukit',
                  latitude: -8.6,
                  longitude: 115.1,
                  difficulty: 'intermediate',
                  bestMonths: const ['May'],
                  waveHeightM: 1,
                  waterTempC: 26,
                  imageUrl: '',
                  summary: 'A surf break.',
                ),
              ];
            }),
            mapEventPostsProvider.overrideWith((_) async {
              eventsCalls++;
              return [];
            }),
            guestSpotsProvider.overrideWith((_) async {
              spotsCalls++;
              return [PublicMapSpotPreview.fromJson(_spotData)];
            }),
            guestEventsProvider.overrideWith((_) async {
              eventsCalls++;
              return [];
            }),
            guestTileProviderFactory.overrideWithValue(_Tiles.new),
            spotsMapTileProviderFactory.overrideWithValue(_Tiles.new),
          ],
        );
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                home: guest ? const GuestExplorePage() : const SpotsMapPage(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final adapter = tester.widget<SurfMapPinchGestures>(
            find.byType(SurfMapPinchGestures),
          );
          final position = tester.getCenter(find.byType(FlutterMap));
          final before = adapter.controller.camera;
          await tester.sendEventToBinding(
            PointerScaleEvent(
              kind: PointerDeviceKind.trackpad,
              position: position,
              scale: 1.1,
            ),
          );
          await tester.pump();
          final zoomed = adapter.controller.camera;
          expect(zoomed.zoom, greaterThan(before.zoom));
          await tester.sendEventToBinding(
            PointerScrollEvent(
              kind: PointerDeviceKind.trackpad,
              position: position,
              scrollDelta: const Offset(35, -25),
            ),
          );
          await tester.pump();
          expect(adapter.controller.camera.center, isNot(zoomed.center));
          expect(adapter.controller.camera.zoom, zoomed.zoom);
          expect(spotsCalls, 1);
          expect(eventsCalls, 1);
          expect(profileCalls, guest ? 0 : 1);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          container.dispose();
          await tester.pump();
        }
      },
    );
  }
}
