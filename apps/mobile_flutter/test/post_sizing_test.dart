import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

void main() {
  for (final viewport in [390.0, 680.0, 800.0, 979.0, 980.0, 1400.0]) {
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
                    child: SocialPostMediaFrame(
                      child: ColoredBox(
                        key: ValueKey('media'),
                        color: Colors.blue,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final post = tester.getRect(find.byKey(const ValueKey('post')));
      final media = tester.getSize(find.byKey(const ValueKey('media')));
      final expectedWidth = viewport.clamp(0, 680).toDouble();
      expect(post.width, expectedWidth);
      expect(post.left, closeTo((viewport - expectedWidth) / 2, 0.01));
      expect(media.height, lessThanOrEqualTo(636));
      expect(media.width, expectedWidth - 44);
      if (viewport == 390) {
        expect(media.height, closeTo(media.width * 5 / 4, 0.01));
      }
      if (viewport >= 680) {
        expect(media.height, 636);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
