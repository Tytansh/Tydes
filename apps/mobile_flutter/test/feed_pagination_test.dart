import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/social_feed_page.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

import 'auth_session_test.dart' show MemorySessions, FakeTransport, body;

UserProfile _viewer(String id) => UserProfile.fromJson({
  'id': id,
  'email': '$id@example.invalid',
  'display_name': 'Paging Surfer',
  'handle': id,
  'surf_skill': 'beginner',
  'home_region': 'Bali',
  'locale': 'en',
  'email_verified': true,
});

SocialFeedEntry _entry(
  int index, {
  String? entryId,
  String? postId,
  String kind = 'post',
  String? body,
}) {
  final id = postId ?? 'post-$index';
  return SocialFeedEntry(
    entryId: entryId ?? '$kind:$id',
    kind: kind,
    activityAt: DateTime.utc(2026, 11, 13).subtract(Duration(minutes: index)),
    post: SocialPostModel.fromJson({
      'id': id,
      'user_id': 'other-surfer',
      'author_name': 'Other Surfer',
      'author_handle': 'other',
      'post_type': 'general',
      'visibility': 'public',
      'body': body ?? 'Post body $id',
      'created_at': '2026-10-01T00:00:00Z',
    }),
  );
}

SocialFeedPage _page(int start, int count, {String? next}) => SocialFeedPage(
  items: List.generate(count, (i) => _entry(start + i)),
  nextCursor: next,
);

void main() {
  test(
    'repository requests a bounded page and sends only the supplied cursor',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.example.invalid'))
        ..httpClientAdapter = FakeTransport((options) async {
          requests.add(options);
          return body({
            'items': [],
            'next_cursor': requests.length == 1 ? 'next' : null,
          });
        });
      final repository = SurfRepository(dio, MemorySessions());
      await repository.fetchSocialFeedPage();
      await repository.fetchSocialFeedPage(cursor: 'next');
      expect(requests.map((request) => request.path), [
        '/social/feed',
        '/social/feed',
      ]);
      expect(requests.first.queryParameters, {'limit': 25});
      expect(requests.last.queryParameters, {'limit': 25, 'cursor': 'next'});
    },
  );

  test(
    'feed transport failure stays a failure rather than seeded success',
    () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.example.invalid'))
        ..httpClientAdapter = FakeTransport((_) async => body({}, 503));
      final repository = SurfRepository(dio, MemorySessions());
      await expectLater(
        repository.fetchSocialFeedPage(),
        throwsA(isA<DioException>()),
      );
    },
  );

  test('feed loads 25 at a time until the cursor is exhausted', () async {
    final cursors = <String?>[];
    final pager = FeedPaginationController(
      accountId: 'viewer',
      loadPage: (cursor) async {
        cursors.add(cursor);
        return switch (cursor) {
          null => _page(0, 25, next: 'page-2'),
          'page-2' => _page(25, 25, next: 'page-3'),
          _ => _page(50, 5),
        };
      },
    );
    addTearDown(pager.dispose);
    final firstPosts = await pager.refreshInitial();
    expect(firstPosts.length, 25);
    expect(pager.state.entries.length, 25);
    expect(cursors, [null]);
    await pager.loadMore();
    expect(pager.state.entries.length, 50);
    await pager.loadMore();
    expect(pager.state.entries.length, 55);
    expect(pager.state.nextCursor, isNull);
    await pager.loadMore();
    expect(cursors, [null, 'page-2', 'page-3']);
  });

  test(
    'server activity order and distinct repost rows survive deduplication',
    () async {
      final repost = _entry(0, kind: 'repost', postId: 'old-post');
      final original = _entry(200, postId: 'old-post');
      final pager = FeedPaginationController(
        accountId: 'viewer',
        loadPage: (cursor) async => cursor == null
            ? SocialFeedPage(items: [repost, _entry(1)], nextCursor: 'more')
            : SocialFeedPage(items: [repost, original, _entry(2)]),
      );
      addTearDown(pager.dispose);
      await pager.refreshInitial();
      await pager.loadMore();
      expect(pager.state.entries.map((entry) => entry.entryId), [
        'repost:old-post',
        'post:post-1',
        'post:old-post',
        'post:post-2',
      ]);
    },
  );

  test(
    'append errors preserve loaded rows and cursor until an explicit retry',
    () async {
      var attempts = 0;
      final pager = FeedPaginationController(
        accountId: 'viewer',
        loadPage: (cursor) async {
          if (cursor == null) return _page(0, 25, next: 'next');
          if (++attempts == 1) throw StateError('offline');
          return _page(25, 3);
        },
      );
      addTearDown(pager.dispose);
      await pager.refreshInitial();
      final first = pager.state.entries;
      await pager.loadMore();
      expect(pager.state.entries, same(first));
      expect(pager.state.nextCursor, 'next');
      expect(pager.state.error, isNotNull);
      await pager.loadMore();
      expect(
        attempts,
        1,
        reason: 'Scroll notifications must not hammer a failed page.',
      );
      await pager.retry();
      expect(pager.state.entries.length, 28);
      expect(pager.state.error, isNull);
    },
  );

  test('simultaneous scroll requests share one append request', () async {
    final pending = Completer<SocialFeedPage>();
    var calls = 0;
    final pager = FeedPaginationController(
      accountId: 'viewer',
      loadPage: (cursor) {
        calls++;
        return cursor == null
            ? Future.value(_page(0, 25, next: 'next'))
            : pending.future;
      },
    );
    addTearDown(pager.dispose);
    await pager.refreshInitial();
    final first = pager.loadMore();
    final second = pager.loadMore();
    expect(second, same(first));
    await Future<void>.value();
    expect(calls, 2);
    pending.complete(_page(25, 25));
    await first;
    expect(pager.state.entries.length, 50);
  });

  test(
    'refresh rejects late append data without blocking the new cursor',
    () async {
      final oldAppend = Completer<SocialFeedPage>();
      final newAppend = Completer<SocialFeedPage>();
      var initialCalls = 0;
      final applied = <String>[];
      final pager = FeedPaginationController(
        accountId: 'viewer',
        loadPage: (cursor) {
          if (cursor == null) {
            return Future.value(
              ++initialCalls == 1
                  ? _page(0, 25, next: 'old-next')
                  : _page(100, 25, next: 'new-next'),
            );
          }
          return cursor == 'old-next' ? oldAppend.future : newAppend.future;
        },
        onPageLoaded: (page) => applied.add(page.items.first.entryId),
      );
      addTearDown(pager.dispose);
      await pager.refreshInitial();
      final old = pager.loadMore();
      await Future<void>.value();
      await pager.refreshInitial();
      final current = pager.loadMore();
      await Future<void>.value();
      oldAppend.complete(_page(25, 25));
      await old;
      expect(pager.state.isLoadingMore, isTrue);
      expect(pager.loadMore(), same(current));
      newAppend.complete(_page(125, 2));
      await current;
      expect(pager.state.entries.first.entryId, 'post:post-100');
      expect(pager.state.entries.length, 27);
      expect(applied, ['post:post-0', 'post:post-100', 'post:post-125']);
    },
  );

  test(
    'old initial results and disposed account requests cannot hydrate state',
    () async {
      final old = Completer<SocialFeedPage>();
      var calls = 0;
      var hydrations = 0;
      final pager = FeedPaginationController(
        accountId: 'old-account',
        loadPage: (_) =>
            ++calls == 1 ? old.future : Future.value(_page(100, 1)),
        onPageLoaded: (_) => hydrations++,
      );
      final request = pager.refreshInitial();
      await Future<void>.value();
      await pager.refreshInitial();
      pager.dispose();
      old.complete(_page(0, 25));
      expect(await request, isEmpty);
      expect(hydrations, 1);
    },
  );

  test('failed first-page refresh retains the last confirmed feed', () async {
    var calls = 0;
    final pager = FeedPaginationController(
      accountId: 'viewer',
      loadPage: (_) async {
        if (++calls == 2) throw StateError('offline');
        return _page(calls == 1 ? 0 : 100, 25, next: 'next');
      },
    );
    addTearDown(pager.dispose);
    await pager.refreshInitial();
    final first = pager.state.entries;
    await expectLater(pager.refreshInitial(), throwsStateError);
    expect(pager.state.entries, same(first));
    expect(pager.state.initialized, isTrue);
    expect(pager.state.refreshFailed, isTrue);
    await pager.retry();
    expect(pager.state.entries.first.entryId, 'post:post-100');
    expect(pager.state.error, isNull);
  });

  test(
    'a non-advancing cursor does not spin through repeated requests',
    () async {
      var calls = 0;
      final pager = FeedPaginationController(
        accountId: 'viewer',
        loadPage: (_) async {
          calls++;
          return _page(0, 1, next: 'same');
        },
      );
      addTearDown(pager.dispose);
      await pager.refreshInitial();
      await pager.loadMore();
      expect(pager.state.error, isNotNull);
      await pager.loadMore();
      expect(calls, 2);
    },
  );

  test('page parser retains scoped engagement without global fallback', () {
    final page = SocialFeedPage.fromJson({
      'items': [],
      'next_cursor': null,
      'scoped_post_ids': ['post-a'],
      'engagement': {
        'liked_post_ids': ['post-a'],
        'reposted_post_ids': [],
        'reposts': [],
        'liked_comment_ids': [],
        'rsvp_post_ids': [],
        'comments': [],
      },
    });
    expect(page.scopedPostIds, ['post-a']);
    expect(page.engagement!.likedPostIds, {'post-a'});
    expect(SocialFeedPage.fromJson({'items': []}).engagement, isNull);
  });

  testWidgets(
    'appending a page preserves the active comment draft and scroll',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pager = FeedPaginationController(
        accountId: 'viewer',
        loadPage: (cursor) async =>
            cursor == null ? _page(0, 25, next: 'next') : _page(25, 25),
      );
      final container = ProviderContainer(
        overrides: [
          meProvider.overrideWith((_) async => _viewer('viewer')),
          feedPaginationProvider.overrideWith((_) => pager),
          travelFeedSpotsProvider.overrideWith((_) async => []),
          socialEngagementHydrationProvider.overrideWith((_) async {}),
          socialRelationshipHydrationProvider.overrideWith((_) async {}),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: CustomScrollView(
                slivers: [TravelFeedSection(showHeader: false, asSliver: true)],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = tester
          .widget<TextField>(find.byType(TextField).first)
          .controller!;
      await tester.enterText(find.byType(TextField).first, 'Keep this draft');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(400);
      await tester.pumpAndSettle();
      final offset = position.pixels;
      await pager.loadMore();
      await tester.pumpAndSettle();
      expect(position.pixels, offset);
      expect(input.text, 'Keep this draft');
      expect(pager.state.entries.length, 50);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('previous account rows stay hidden while a new account loads', (
    tester,
  ) async {
    final owner = StateProvider<String>((_) => 'account-a');
    final pendingB = Completer<SocialFeedPage>();
    var bRequests = 0;
    final container = ProviderContainer(
      overrides: [
        meProvider.overrideWith((ref) async => _viewer(ref.watch(owner))),
        feedPaginationProvider.overrideWith((ref) {
          final id = ref.watch(owner);
          return FeedPaginationController(
            accountId: id,
            loadPage: (_) => id == 'account-a'
                ? Future.value(
                    SocialFeedPage(
                      items: [_entry(0, body: 'Account A private row')],
                    ),
                  )
                : ++bRequests == 1
                ? pendingB.future
                : Future.value(
                    SocialFeedPage(items: [_entry(1, body: 'Account B row')]),
                  ),
          );
        }),
        travelFeedSpotsProvider.overrideWith((_) async => []),
        socialEngagementHydrationProvider.overrideWith((_) async {}),
        socialRelationshipHydrationProvider.overrideWith((_) async {}),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [TravelFeedSection(showHeader: false, asSliver: true)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Account A private row'), findsOneWidget);
    container.read(owner.notifier).state = 'account-b';
    await tester.pump();
    await tester.pump();
    expect(find.text('Account A private row'), findsNothing);
    pendingB.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Account A private row'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Retry posts'), findsOneWidget);
    await tester.tap(find.text('Retry posts'));
    await tester.pumpAndSettle();
    expect(find.text('Account B row'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
