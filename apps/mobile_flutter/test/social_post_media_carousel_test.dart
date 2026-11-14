import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/features/social/post_media_zoom.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

void main() {
  testWidgets('pinch callbacks lock then unlock the real media carousel', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 500,
              child: SocialPostMediaCarousel(
                media: [
                  for (final id in ['photo-a', 'photo-b'])
                    SocialMediaAttachmentModel.fromJson({
                      'id': id,
                      'url': 'https://image.example.invalid/$id.jpg',
                      'thumbnail_url': '',
                    }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final position = tester.getCenter(find.byType(PostMediaZoom).first);
    expect(
      tester.widget<PageView>(find.byType(PageView)).physics,
      isA<PageScrollPhysics>(),
    );
    await tester.sendEventToBinding(
      PointerScaleEvent(position: position, scale: 1.5),
    );
    await tester.pump();
    expect(
      tester.widget<PageView>(find.byType(PageView)).physics,
      isA<NeverScrollableScrollPhysics>(),
    );
    await tester.sendEventToBinding(
      PointerScaleEvent(position: position, scale: 1 / 1.5),
    );
    await tester.pump();
    expect(
      tester.widget<PageView>(find.byType(PageView)).physics,
      isA<PageScrollPhysics>(),
    );
    await tester.drag(find.byType(PageView), const Offset(-350, 0));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page,
      closeTo(1, 0.001),
    );
    expect(tester.takeException(), isNull);
  });

  test('web carousel uses arrows instead of mouse dragging at every width', () {
    expect(
      socialPostMediaCarouselPhysics(isWeb: true),
      isA<NeverScrollableScrollPhysics>(),
    );
    expect(
      socialPostMediaCarouselShowsArrows(isWeb: true, mediaCount: 3),
      isTrue,
    );
  });

  test('native carousel keeps touch swiping', () {
    expect(
      socialPostMediaCarouselPhysics(isWeb: false),
      isA<PageScrollPhysics>(),
    );
    expect(
      socialPostMediaCarouselShowsArrows(isWeb: false, mediaCount: 3),
      isFalse,
    );
  });

  test('web carousel hides arrows for a single media item', () {
    expect(
      socialPostMediaCarouselShowsArrows(isWeb: true, mediaCount: 1),
      isFalse,
    );
  });

  test('video only plays when its slide is active and visible', () {
    expect(
      socialVideoShouldPlay(
        active: true,
        userPaused: false,
        mostlyVisible: true,
      ),
      isTrue,
    );
    expect(
      socialVideoShouldPlay(
        active: false,
        userPaused: false,
        mostlyVisible: true,
      ),
      isFalse,
    );
    expect(
      socialVideoShouldPlay(
        active: true,
        userPaused: false,
        mostlyVisible: false,
      ),
      isFalse,
    );
  });
}
