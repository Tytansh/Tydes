import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/widgets/feed_refresh_indicator.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/public_profile_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

import 'auth_session_test.dart' show MemorySessions;

UserProfile _viewer(String id, {bool verified = true}) => UserProfile.fromJson({
  'id': id,
  'email': '$id@example.invalid',
  'display_name': id,
  'handle': id,
  'surf_skill': 'beginner',
  'home_region': 'Bali',
  'locale': 'en',
  'email_verified': verified,
});

SocialPostModel _post(String body) => SocialPostModel.fromJson({
  'id': body,
  'user_id': 'other',
  'author_name': 'Other surfer',
  'author_handle': 'other',
  'post_type': 'general',
  'visibility': 'followers',
  'body': body,
  'created_at': '2026-11-13T10:00:00Z',
});

class _Repository extends SurfRepository {
  _Repository() : super(Dio(), MemorySessions());

  int accountReads = 0;
  int spotReads = 0;
  int friendReads = 0;
  int profileReads = 0;
  int postReads = 0;
  Future<List<SocialPostModel>> Function()? readPosts;

  @override
  Future<UserProfile> fetchMe() async {
    accountReads++;
    return _viewer('viewer-a');
  }

  @override
  Future<List<SpotModel>> fetchSpots() async {
    spotReads++;
    return [];
  }

  @override
  Future<List<FriendProfileModel>> fetchFriends() async {
    friendReads++;
    return [];
  }

  @override
  Future<List<SocialProfileModel>> fetchSocialProfiles() async {
    profileReads++;
    return [];
  }

  @override
  Future<List<SocialPostModel>> fetchSocialPosts() async {
    postReads++;
    return readPosts == null ? [] : readPosts!();
  }
}

final _activeViewer = StateProvider<UserProfile>((_) => _viewer('viewer-a'));

Future<ProviderContainer> _show(
  WidgetTester tester,
  _Repository repository, {
  bool primeSharedData = true,
  bool verified = true,
}) async {
  final container = ProviderContainer(
    overrides: [
      surfRepositoryProvider.overrideWithValue(repository),
      _activeViewer.overrideWith(
        (_) => _viewer('viewer-a', verified: verified),
      ),
      meProvider.overrideWith((ref) async => ref.watch(_activeViewer)),
      socialEngagementHydrationProvider.overrideWith((_) async {}),
      socialRelationshipHydrationProvider.overrideWith((_) async {}),
    ],
  );
  addTearDown(container.dispose);
  if (primeSharedData) {
    await container.read(meProvider.future);
    await container.read(travelFeedSpotsProvider.future);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: PublicProfilePage(userId: 'other')),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  testWidgets('opening and refreshing a profile reuse account and catalog', (
    tester,
  ) async {
    final repository = _Repository();
    await _show(tester, repository);
    await tester.pumpAndSettle();
    expect(repository.accountReads, 0);
    expect(repository.spotReads, 1);
    expect(repository.friendReads, 1);
    expect(repository.postReads, 1);
    expect(repository.profileReads, 1);

    final refresh = tester
        .widget<FeedRefreshIndicator>(find.byType(FeedRefreshIndicator))
        .onRefresh();
    await tester.pump();
    await refresh;
    await tester.pumpAndSettle();
    expect(repository.accountReads, 0);
    expect(repository.spotReads, 1);
    expect(repository.friendReads, 2);
    expect(repository.postReads, 2);
    expect(repository.profileReads, 2);
  });

  testWidgets('an account change hides retained private profile data', (
    tester,
  ) async {
    final repository = _Repository()
      ..readPosts = () async => [_post('Only viewer A can see this')];
    final container = await _show(tester, repository);
    await tester.pumpAndSettle();
    expect(find.text('Only viewer A can see this'), findsOneWidget);

    final pending = Completer<List<SocialPostModel>>();
    repository.readPosts = () => pending.future;
    container.read(_activeViewer.notifier).state = _viewer('viewer-b');
    await tester.pump();
    await tester.pump();
    expect(find.text('Only viewer A can see this'), findsNothing);
    pending.complete([_post('Visible to viewer B')]);
    await tester.pumpAndSettle();
    expect(find.text('Visible to viewer B'), findsOneWidget);
    expect(find.text('Only viewer A can see this'), findsNothing);
  });

  testWidgets('late previous-account profile results cannot replace new data', (
    tester,
  ) async {
    final old = Completer<List<SocialPostModel>>();
    final repository = _Repository()..readPosts = () => old.future;
    final container = await _show(tester, repository);
    repository.readPosts = () async => [_post('New account result')];
    container.read(_activeViewer.notifier).state = _viewer('viewer-b');
    await tester.pumpAndSettle();
    expect(find.text('New account result'), findsOneWidget);
    old.complete([_post('Old private response')]);
    await tester.pumpAndSettle();
    expect(find.text('Old private response'), findsNothing);
    expect(find.text('New account result'), findsOneWidget);
  });

  testWidgets('unverified accounts do not start private profile requests', (
    tester,
  ) async {
    final repository = _Repository();
    await _show(tester, repository, primeSharedData: false, verified: false);
    await tester.pumpAndSettle();
    expect(repository.accountReads, 0);
    expect(repository.spotReads, 0);
    expect(repository.friendReads, 0);
    expect(repository.postReads, 0);
    expect(repository.profileReads, 0);
  });

  testWidgets('losing verification hides retained same-account profile data', (
    tester,
  ) async {
    final repository = _Repository()
      ..readPosts = () async => [_post('Verified-only data')];
    final container = await _show(tester, repository);
    await tester.pumpAndSettle();
    expect(find.text('Verified-only data'), findsOneWidget);
    container.read(_activeViewer.notifier).state = _viewer(
      'viewer-a',
      verified: false,
    );
    await container.read(meProvider.future);
    await tester.pump();
    expect(find.text('Verified-only data'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('Verified-only data'), findsNothing);
    expect(repository.postReads, 1);
  });
}
