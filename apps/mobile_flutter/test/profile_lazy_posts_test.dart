import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/settings/settings_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';
import 'package:mobile_flutter/features/spots/spots_page.dart';

final _viewer = UserProfile.fromJson({
  'id': 'lazy-profile-viewer',
  'email': 'profile@example.invalid',
  'display_name': 'Profile Surfer',
  'handle': 'profile',
  'surf_skill': 'beginner',
  'home_region': 'Bali',
  'locale': 'en',
  'email_verified': true,
});

SocialPostModel _post(int index, {String? userId, bool media = false}) =>
    SocialPostModel.fromJson({
      'id': 'profile-$index',
      'user_id': userId ?? _viewer.id,
      'author_name': userId == null ? _viewer.displayName : 'Other Surfer',
      'author_handle': userId == null ? _viewer.handle : 'other',
      'visibility': 'public',
      'post_type': 'general',
      'body': 'Profile post $index',
      'created_at': DateTime.utc(
        2026,
        11,
        13,
      ).subtract(Duration(minutes: index)).toIso8601String(),
      if (media)
        'media': [
          {
            'id': 'photo-$index',
            'media_type': 'photo',
            'url': 'https://fixture.example.invalid/photo.jpg',
            'thumbnail_url': 'https://fixture.example.invalid/photo.jpg',
          },
        ],
    });

Future<ProviderContainer> _show(
  WidgetTester tester,
  List<SocialPostModel> posts, {
  List<String> reposts = const [],
  Map<String, DateTime> repostTimes = const {},
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      meProvider.overrideWith((_) async => _viewer),
      friendsProvider.overrideWith((_) async => []),
      socialProfilesProvider.overrideWith((_) async => []),
      socialPostsProvider.overrideWith((_) async => posts),
      spotsProvider.overrideWith((_) async => []),
      socialEngagementHydrationProvider.overrideWith((_) async {}),
      socialRelationshipHydrationProvider.overrideWith((_) async {}),
      visibleRepostedPostIdsProvider.overrideWith((_) => reposts),
      visibleRepostActivityTimesProvider.overrideWith((_) => repostTimes),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsPage()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('profile mounts only nearby media and retains comment drafts', (
    tester,
  ) async {
    await _show(tester, List.generate(100, (i) => _post(i, media: true)));
    final mounted = find.byType(SocialPostMediaCarousel).evaluate().length;
    debugPrint('Profile 100-post fixture: $mounted media carousels mounted');
    expect(mounted, greaterThan(0));
    expect(mounted, lessThan(8));
    await tester.enterText(find.byType(TextField).first, 'Unsaved comment');
    tester.testTextInput.hide();
    await tester.pump();
    final scrollable = find
        .descendant(
          of: find.byType(SettingsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('profile_post_profile-25')),
      700,
      scrollable: scrollable,
      maxScrolls: 60,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('profile_post_profile-25')),
      findsOneWidget,
    );
    expect(find.byType(SocialPostMediaCarousel).evaluate().length, lessThan(8));
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'Unsaved comment',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('profile keeps repost activity and own posts in the same order', (
    tester,
  ) async {
    await _show(
      tester,
      [_post(0), _post(1), _post(2, userId: 'other-surfer')],
      reposts: ['profile-2'],
      repostTimes: {'profile-2': DateTime.utc(2026, 11, 14)},
    );
    tester.view.physicalSize = const Size(390, 1800);
    await tester.pumpAndSettle();
    final ids = tester
        .widgetList<PostEngagementBar>(find.byType(PostEngagementBar))
        .map((bar) => bar.post.id)
        .toList();
    expect(ids, ['profile-2', 'profile-0', 'profile-1']);
    expect(find.text('You reposted'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('profile_repost_You reposted_profile-2')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
