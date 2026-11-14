import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile_flutter/features/spots/map_pinch_gestures.dart';

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
}
