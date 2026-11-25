import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

void main() {
  for (final viewport in [
    320.0,
    390.0,
    430.0,
    680.0,
    800.0,
    979.0,
    980.0,
    1400.0,
  ]) {
    testWidgets('post and media stay bounded at viewport $viewport', (
      tester,
    ) async {
      tester.view.physicalSize = Size(viewport, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TydesDesktopPostWidth(
                child: SizedBox(
                  key: ValueKey('post'),
                  width: double.infinity,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SocialPostMediaFrame(
                          child: ColoredBox(
                            key: ValueKey('media'),
                            color: Colors.blue,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final post = tester.getRect(find.byKey(const ValueKey('post')));
      final media = tester.getRect(find.byKey(const ValueKey('media')));
      final expectedWidth = viewport.clamp(0, 680).toDouble();
      final expectedStageWidth = expectedWidth - 44;
      expect(post.width, expectedWidth);
      expect(post.left, closeTo((viewport - expectedWidth) / 2, 0.01));
      if (viewport >= 600) {
        expect(media.height, lessThanOrEqualTo(650));
      }
      expect(media.width, closeTo(expectedStageWidth, 0.01));
      expect(media.width / media.height, closeTo(1, 0.00001));
      expect(media.center.dx, closeTo(viewport / 2, 0.01));
      if (viewport >= 600) {
        expect(media.height, expectedStageWidth);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('resizing preserves natural proportions and desktop post cap', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(390, 1200);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TydesDesktopPostWidth(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 22),
                child: SocialPostMediaFrame(
                  naturalAspectRatio: 16 / 9,
                  child: ColoredBox(
                    key: ValueKey('resize-media'),
                    color: Colors.blue,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final stage = tester.element(find.byKey(const ValueKey('resize-media')));
    for (final viewport in [390.0, 1400.0, 430.0, 320.0]) {
      tester.view.physicalSize = Size(viewport, 1200);
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(const ValueKey('resize-media')));
      final contentWidth = viewport.clamp(0.0, 680.0) - 44;
      final expectedWidth = contentWidth;
      expect(rect.width, closeTo(expectedWidth, 0.01));
      if (viewport >= 600) {
        expect(rect.height, lessThanOrEqualTo(650));
      }
      expect(rect.width / rect.height, closeTo(16 / 9, 0.00001));
      expect(rect.center.dx, closeTo(viewport / 2, 0.01));
      expect(
        tester.element(find.byKey(const ValueKey('resize-media'))),
        same(stage),
      );
      expect(tester.takeException(), isNull);
    }
  });

  for (final ratio in [16 / 9, 1.0, 9 / 16, 9 / 21]) {
    testWidgets('desktop ratio $ratio uses its natural height up to 650px', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TydesDesktopPostWidth(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: SocialPostMediaFrame(
                    naturalAspectRatio: ratio,
                    child: const ColoredBox(
                      key: ValueKey('natural-desktop'),
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(
        find.byKey(const ValueKey('natural-desktop')),
      );
      expect(rect.width, 636);
      expect(rect.height, closeTo((636 / ratio).clamp(0.0, 650.0), .00001));
      expect(rect.center.dx, 700);
      expect(tester.takeException(), isNull);
    });
  }
}
