import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

final _post = SocialPostModel.fromJson({
  'id': 'edge-to-edge',
  'user_id': DemoSeed.me.id,
  'author_name': 'Surfer',
  'post_type': 'general',
  'body': 'The full photo, without cropping.',
  'created_at': '2026-11-19T00:00:00Z',
  'media': [
    {
      'id': 'whole-photo',
      'media_type': 'photo',
      'url': 'https://media.example.invalid/photo.png',
      'thumbnail_url': '',
    },
  ],
});

void main() {
  for (final width in [320.0, 390.0, 430.0, 599.0, 600.0, 800.0, 1400.0]) {
    testWidgets('feed media fills phones, not desktop at width $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            meProvider.overrideWith((_) async => DemoSeed.me),
            travelFeedPostsProvider.overrideWith((_) async => [_post]),
            travelFeedSpotsProvider.overrideWith((_) async => []),
            socialRelationshipHydrationProvider.overrideWith((_) async {}),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PageView), findsOneWidget);
      final media = tester.getRect(find.byType(PageView));
      final card = tester.getRect(
        find.ancestor(of: find.byType(PageView), matching: find.byType(Card)),
      );
      final carouselClip = find.descendant(
        of: find.byType(SocialPostMediaCarousel),
        matching: find.byType(ClipRRect),
      );
      final radius = tester.widget<ClipRRect>(carouselClip.first).borderRadius;
      expect(media.width / media.height, closeTo(9 / 16, .00001));
      if (width < 600) {
        expect(card.left, 0);
        expect(card.right, width);
        expect(media.left, 0);
        expect(media.right, width);
        expect(media.height, closeTo(width * 16 / 9, .00001));
        expect(radius, BorderRadius.zero);
      } else {
        expect(media.width, closeTo(636 * 9 / 16, .00001));
        expect(media.height, 636);
        expect(media.center.dx, closeTo(width / 2, .00001));
        expect(radius, BorderRadius.circular(18));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
