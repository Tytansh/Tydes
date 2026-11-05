import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/post_media_zoom.dart';

void main() {
  Matrix4 transform(WidgetTester tester) => tester
      .widget<Transform>(
        find.byKey(const ValueKey('post-media-zoom-transform')).first,
      )
      .transform;

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
