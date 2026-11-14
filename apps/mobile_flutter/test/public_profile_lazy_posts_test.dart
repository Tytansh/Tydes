import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/public_profile_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

import 'auth_session_test.dart' show MemorySessions;

final _viewer = UserProfile.fromJson({
  'id': 'public-profile-viewer',
  'email': 'profile@example.invalid',
  'display_name': 'Profile Surfer',
  'handle': 'profile',
  'surf_skill': 'beginner',
  'home_region': 'Bali',
  'locale': 'en',
  'email_verified': true,
});

SocialPostModel _post(int index, {bool media = false, String? spotId}) =>
    SocialPostModel.fromJson({
      'id': 'public-profile-$index',
      'user_id': 'other-surfer',
      'author_name': 'Other Surfer',
      'author_handle': 'other',
      'visibility': 'public',
      'post_type': 'general',
      'spot_id': spotId,
      'body': 'Profile post $index',
      'created_at': DateTime.utc(
        2026,
        11,
        13,
      ).subtract(Duration(minutes: index)).toIso8601String(),
      if (media)
        'media': [
          {
            'id': 'public-photo-$index',
            'media_type': 'photo',
            'url': 'https://fixture.example.invalid/photo.jpg',
            'thumbnail_url': 'https://fixture.example.invalid/photo.jpg',
          },
        ],
    });

SpotModel _spot(int index) => SpotModel.fromJson({
  'id': 'fixture-spot-$index',
  'name': 'Fixture spot $index',
  'country': 'Indonesia',
  'region': 'Bali',
  'area': 'Canggu',
  'latitude': -8.6,
  'longitude': 115.1,
  'difficulty': 'beginner',
  'best_months': <String>[],
  'wave_height_m': 1,
  'water_temp_c': 28,
  'image_url': '',
  'summary': '',
});

class _CountingSpots extends ListBase<SpotModel> {
  _CountingSpots(this.values);
  final List<SpotModel> values;
  int reads = 0;

  @override
  int get length => values.length;

  @override
  set length(int value) => throw UnsupportedError('Read-only fixture');

  @override
  SpotModel operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, SpotModel value) =>
      throw UnsupportedError('Read-only fixture');
}

class _ProfileRepository extends SurfRepository {
  _ProfileRepository(this.posts) : super(Dio(), MemorySessions());

  final List<SocialPostModel> posts;

  @override
  Future<UserProfile> fetchMe() async => _viewer;

  @override
  Future<List<FriendProfileModel>> fetchFriends() async => [];

  @override
  Future<List<SocialPostModel>> fetchSocialPosts() async => posts;

  @override
  Future<List<SpotModel>> fetchSpots() async => [];

  @override
  Future<List<SocialProfileModel>> fetchSocialProfiles() async => [];
}

Future<ProviderContainer> _show(
  WidgetTester tester,
  List<SocialPostModel> posts, {
  List<SpotModel> spots = const [],
  Set<String> blocked = const {},
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      surfRepositoryProvider.overrideWithValue(_ProfileRepository(posts)),
      meProvider.overrideWith((_) async => _viewer),
      currentViewerProvider.overrideWith((_) async => _viewer),
      travelFeedSpotsProvider.overrideWith((_) async => spots),
      blockedUserIdsProvider.overrideWith((_) => blocked),
      socialEngagementHydrationProvider.overrideWith((_) async {}),
      socialRelationshipHydrationProvider.overrideWith((_) async {}),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: PublicProfilePage(userId: 'other-surfer')),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets(
    'public profile bounds mounted media and retains comment drafts',
    (tester) async {
      await _show(tester, List.generate(100, (i) => _post(i, media: true)));
      final mounted = find.byType(SocialPostMediaCarousel).evaluate().length;
      debugPrint('Public profile 100-post fixture: $mounted media mounted');
      expect(mounted, greaterThan(0));
      expect(mounted, lessThan(8));
      final list = tester.widget<ListView>(find.byType(ListView).first);
      expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
      expect(list.childrenDelegate.estimatedChildCount, 101);
      await tester.enterText(
        find.byType(TextField).first,
        'Unsaved public comment',
      );
      tester.testTextInput.hide();
      await tester.pump();
      final scrollable = find
          .descendant(
            of: find.byType(PublicProfilePage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('public_profile_post_public-profile-25')),
        700,
        scrollable: scrollable,
        maxScrolls: 60,
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(SocialPostMediaCarousel).evaluate().length,
        lessThan(8),
      );
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Unsaved public comment',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets('public profile indexes the spot catalog once per rebuild', (
    tester,
  ) async {
    final spots = _CountingSpots(List.generate(384, _spot));
    final container = await _show(
      tester,
      List.generate(100, (i) => _post(i, spotId: 'fixture-spot-383')),
      spots: spots,
    );
    debugPrint(
      'Public profile 100-post/384-spot fixture: ${spots.reads} reads',
    );
    // Previously every preconstructed row scanned all 384 spots: 38,400 reads
    // per page build. Indexing the catalog performs only one 384-item pass.
    expect(spots.reads, lessThan(384 * 4));
    expect(find.text('Fixture spot 383'), findsWidgets);
    spots.reads = 0;
    container.read(blockedUserIdsProvider.notifier).state = {'unrelated-user'};
    await tester.pump();
    expect(spots.reads, 384);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blocked public profiles retain their notice but hide posts', (
    tester,
  ) async {
    await _show(
      tester,
      List.generate(100, (i) => _post(i, media: true)),
      blocked: {'other-surfer'},
    );
    expect(find.text('Other Surfer'), findsOneWidget);
    expect(find.textContaining('You blocked this surfer'), findsOneWidget);
    expect(find.byType(SocialPostMediaCarousel), findsNothing);
    expect(find.byType(PostEngagementBar), findsNothing);
    expect(find.text('No posts yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
