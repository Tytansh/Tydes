import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/post_media_zoom.dart';

void main() {
  Matrix4 transform(WidgetTester tester) => tester
      .widget<Transform>(
        find.byKey(const ValueKey('post-media-zoom-transform')).first,
      )
      .transform;

  Future<void> showZoom(
    WidgetTester tester, {
    ValueChanged<bool>? onZoomChanged,
    ScrollController? scroll,
    bool showControls = false,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          controller: scroll,
          children: [
            const SizedBox(height: 83),
            Padding(
              padding: const EdgeInsets.only(left: 71, right: 129),
              child: SizedBox(
                height: 400,
                child: PostMediaZoom(
                  onZoomChanged: onZoomChanged,
                  showControls: showControls,
                  child: const ColoredBox(
                    color: Colors.blue,
                    child: Text('Original media'),
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

  Future<void> signal(WidgetTester tester, double scale) async {
    await tester.sendEventToBinding(
      PointerScaleEvent(
        position: tester.getCenter(find.byType(PostMediaZoom)),
        scale: scale,
      ),
    );
    await tester.pump();
  }

  testWidgets('browser trackpad pinch uses current scale around its cursor', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.only(left: 71, top: 83),
            child: SizedBox.square(
              dimension: 400,
              child: PostMediaZoom(
                onZoomChanged: changes.add,
                child: const ColoredBox(color: Colors.blue),
              ),
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(PostMediaZoom));
    final position = rect.topLeft + const Offset(130, 170);
    for (final scale in [1.2, 1.2]) {
      await tester.sendEventToBinding(
        PointerScaleEvent(position: position, scale: scale),
      );
      await tester.pump();
    }
    expect(transform(tester).getMaxScaleOnAxis(), closeTo(1.44, 1e-9));
    expect(transform(tester).storage[12], closeTo(130 * (1 - 1.44), 1e-9));
    expect(transform(tester).storage[13], closeTo(170 * (1 - 1.44), 1e-9));
    expect(changes, [true]);
    await tester.sendEventToBinding(
      PointerScaleEvent(position: position, scale: 1 / 1.44),
    );
    await tester.pump();
    expect(transform(tester), Matrix4.identity());
    expect(changes, [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('browser pinch ignores invalid scales and clamps at 1x and 4x', (
    tester,
  ) async {
    final changes = <bool>[];
    await showZoom(tester, onZoomChanged: changes.add);
    for (final scale in [
      0.0,
      -1.0,
      double.nan,
      double.infinity,
      -double.infinity,
      1.0,
    ]) {
      await signal(tester, scale);
      expect(transform(tester), Matrix4.identity());
    }
    expect(changes, isEmpty);
    await signal(tester, 1e20);
    expect(transform(tester).getMaxScaleOnAxis(), 4);
    final atLimit = transform(tester);
    await signal(tester, 1e20);
    expect(transform(tester), atLimit);
    await signal(tester, 1e-20);
    expect(transform(tester), Matrix4.identity());
    expect(changes, [true, false]);
    expect(find.byTooltip('Reset zoom'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tiny browser pinch resets instead of zooming farther', (
    tester,
  ) async {
    final changes = <bool>[];
    await showZoom(tester, onZoomChanged: changes.add);
    await signal(tester, 1.005);
    expect(transform(tester).getMaxScaleOnAxis(), closeTo(1.005, 1e-9));
    expect(find.byTooltip('Reset zoom'), findsOneWidget);
    await tester.tap(find.byTooltip('Reset zoom'));
    await tester.pumpAndSettle();
    expect(transform(tester), Matrix4.identity());
    expect(changes, [true, false]);
  });

  testWidgets('wheel scroll stays page scrolling even while media is zoomed', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await showZoom(tester, scroll: scroll);
    final media = tester.element(find.text('Original media'));
    await signal(tester, 1.5);
    final matrix = transform(tester).clone();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(PostMediaZoom)),
        scrollDelta: const Offset(0, 100),
      ),
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(transform(tester), matrix);
    expect(tester.element(find.text('Original media')), same(media));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new browser pinch interrupts reset at its current scale', (
    tester,
  ) async {
    final changes = <bool>[];
    await showZoom(tester, onZoomChanged: changes.add);
    await signal(tester, 2);
    await tester.tap(find.byTooltip('Reset zoom'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final duringReset = transform(tester).getMaxScaleOnAxis();
    expect(duringReset, inExclusiveRange(1, 2));
    await signal(tester, 1.2);
    final resumedScale = transform(tester).getMaxScaleOnAxis();
    expect(resumedScale, closeTo(duringReset * 1.2, 1e-9));
    await tester.pump(const Duration(milliseconds: 300));
    expect(transform(tester).getMaxScaleOnAxis(), resumedScale);
    expect(changes, [true]);
    await signal(tester, 1 / resumedScale);
    expect(transform(tester), Matrix4.identity());
    expect(changes, [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native trackpad pinch after browser zoom still snaps back', (
    tester,
  ) async {
    final changes = <bool>[];
    await showZoom(tester, onZoomChanged: changes.add);
    await signal(tester, 1.5);
    final position = tester.getCenter(find.byType(PostMediaZoom));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(position);
    await gesture.panZoomUpdate(position, scale: 1.2);
    await tester.pump();
    await gesture.panZoomUpdate(position, scale: 1.4);
    await tester.pump();
    expect(transform(tester).getMaxScaleOnAxis(), greaterThan(1.5));
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();
    expect(transform(tester), Matrix4.identity());
    expect(changes, [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('touch pinch after browser zoom still snaps back', (
    tester,
  ) async {
    final changes = <bool>[];
    await showZoom(tester, onZoomChanged: changes.add);
    await signal(tester, 1.5);
    final position = tester.getCenter(find.byType(PostMediaZoom));
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
    await left.moveBy(const Offset(-30, 0));
    await right.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(transform(tester).getMaxScaleOnAxis(), greaterThan(1.5));
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(transform(tester), Matrix4.identity());
    expect(changes, [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinch enlarges media and release restores its original size', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 400,
              child: PostMediaZoom(child: ColoredBox(color: Colors.blue)),
            ),
          ),
        ),
      ),
    );
    final center = tester.getCenter(find.byType(PostMediaZoom));
    final first = await tester.startGesture(center - const Offset(45, 0));
    final second = await tester.startGesture(
      center + const Offset(45, 0),
      pointer: 2,
    );
    await first.moveTo(center - const Offset(85, 0));
    await second.moveTo(center + const Offset(85, 0));
    await tester.pump();
    await first.moveTo(center - const Offset(140, 0));
    await second.moveTo(center + const Offset(140, 0));
    await tester.pump();
    expect(transform(tester).getMaxScaleOnAxis(), greaterThan(1.2));
    expect(transform(tester).getMaxScaleOnAxis(), lessThanOrEqualTo(4));
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(transform(tester).getMaxScaleOnAxis(), closeTo(1, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('one finger can still swipe carousel pages and scroll the feed', (
    tester,
  ) async {
    final page = PageController();
    final scroll = ScrollController();
    addTearDown(page.dispose);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: [
              SizedBox(
                height: 300,
                child: PageView(
                  controller: page,
                  children: const [
                    PostMediaZoom(child: ColoredBox(color: Colors.blue)),
                    PostMediaZoom(child: ColoredBox(color: Colors.teal)),
                  ],
                ),
              ),
              const SizedBox(height: 1500),
            ],
          ),
        ),
      ),
    );
    await tester.drag(find.byType(PageView), const Offset(-650, 0));
    await tester.pumpAndSettle();
    expect(page.page, closeTo(1, 0.001));
    await tester.drag(find.byType(PageView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(transform(tester).getMaxScaleOnAxis(), closeTo(1, 0.001));
  });

  testWidgets('desktop zoom controls keep the original media widget mounted', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox.square(
            dimension: 400,
            child: PostMediaZoom(
              showControls: true,
              child: ColoredBox(color: Colors.blue, child: Text('Media')),
            ),
          ),
        ),
      ),
    );
    final media = tester.element(find.text('Media'));
    await tester.tap(find.byTooltip('Zoom media'));
    await tester.pump();
    expect(transform(tester).getMaxScaleOnAxis(), closeTo(2.5, 0.001));
    expect(tester.element(find.text('Media')), same(media));
    await tester.tap(find.byTooltip('Reset zoom'));
    await tester.pumpAndSettle();
    expect(transform(tester).getMaxScaleOnAxis(), closeTo(1, 0.001));
    expect(tester.element(find.text('Media')), same(media));
  });
}
