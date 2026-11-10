import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/spots/map_events.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

final _spot = DemoSeed.spots.first;
final _now = DateTime(2026, 11, 5);

SocialPostModel _event(
  String id, {
  String owner = 'host',
  String visibility = 'public',
  String? start = '2026-11-06',
  String? end,
  String type = 'surf_plan',
  String? spotId,
  String authorName = 'Maya Surfer',
}) => SocialPostModel(
  id: id,
  userId: owner,
  authorName: authorName,
  authorHandle: 'maya',
  authorAvatarUrl: null,
  authorPremium: false,
  spotId: spotId ?? _spot.id,
  postType: type,
  visibility: visibility,
  body: 'Meetup $id',
  media: const [],
  meetupDate: start,
  meetupEndDate: end,
  createdAt: '2026-11-01T10:00:00Z',
);

SocialEngagementModel _engagement(Set<String> joined) => SocialEngagementModel(
  likedPostIds: const {},
  repostedPostIds: const [],
  reposts: const [],
  likedCommentIds: const {},
  rsvpPostIds: joined,
  comments: const [],
);

class _EventRepository extends SurfRepository {
  _EventRepository() : super(Dio(), DemoPersistence());
  final joined = <String>{};
  final requests = <String>[];

  @override
  Future<SocialEngagementModel> setEventRsvp({
    required String postId,
    required bool joined,
  }) async {
    requests.add(postId);
    if (joined) {
      this.joined.add(postId);
    } else {
      this.joined.remove(postId);
    }
    return _engagement(this.joined.toSet());
  }
}

void main() {
  testWidgets('shared beach marker prefers the viewers own host avatar', (
    tester,
  ) async {
    final group = buildMapEventGroups(
      posts: [
        _event('other'),
        _event('own', owner: 'viewer', authorName: 'Your Name'),
      ],
      spots: [_spot],
      now: _now,
      viewerId: 'viewer',
    ).single;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 62,
            child: MapEventMarker(
              group: group,
              viewerId: 'viewer',
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TydesProfileAvatar>(find.byType(TydesProfileAvatar))
          .displayName,
      'Your Name',
    );
    expect(group.events, hasLength(2));
  });

  test('map groups real dated events, including ongoing multi-day events', () {
    final groups = buildMapEventGroups(
      posts: [
        _event('first'),
        _event('second', start: '2026-11-08'),
        _event('ongoing', start: '2026-11-03', end: '2026-11-06'),
        _event('expired', start: '2026-11-01'),
        _event('undated', start: null),
        _event('regular', type: 'general'),
        _event('unknown_location', spotId: 'not_a_spot'),
      ],
      spots: [_spot],
      now: _now,
    );
    expect(groups, hasLength(1));
    expect(groups.single.events.map((event) => event.post.id), [
      'ongoing',
      'first',
      'second',
    ]);
    expect(groups.single.spot.latitude, _spot.latitude);
    expect(groups.single.matches('maya'), isTrue);
    expect(groups.single.matches(_spot.country), isTrue);
  });

  test('private and blocked-host events do not leak onto the map', () {
    final groups = buildMapEventGroups(
      posts: [
        _event('public'),
        _event('own', owner: 'me', visibility: 'followers'),
        _event('followed', owner: 'friend', visibility: 'followers'),
        _event('private', owner: 'stranger', visibility: 'followers'),
        _event('blocked', owner: 'blocked'),
      ],
      spots: [_spot],
      now: _now,
      viewerId: 'me',
      followedUserIds: {'friend'},
      blockedUserIds: {'blocked'},
    );
    expect(groups.single.events.map((event) => event.post.id).toSet(), {
      'public',
      'own',
      'followed',
    });
  });

  testWidgets(
    'host marker opens event popup and lets you select the original post',
    (tester) async {
      final group = buildMapEventGroups(
        posts: [_event('first'), _event('second')],
        spots: [_spot],
        now: _now,
      ).single;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(
              body: Center(
                child: SizedBox.square(
                  dimension: 62,
                  child: MapEventMarker(
                    group: group,
                    onTap: () => showMapEventPopup(context, group),
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/post/:id',
            builder: (_, state) =>
                Scaffold(body: Text('Opened ${state.pathParameters['id']}')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            meProvider.overrideWith(
              (_) async => DemoSeed.me.copyWith(id: 'viewer'),
            ),
            mapEventEngagementProvider.overrideWith(
              (_) async => _engagement({}),
            ),
            mapEventAttendeesProvider.overrideWith((_, _) async => []),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('map-event-marker-${_spot.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Meetup first'), findsOneWidget);
      expect(find.text('@maya · Event host'), findsOneWidget);
      expect(find.text('Join now'), findsOneWidget);
      final selectors = find.byType(ChoiceChip);
      expect(selectors, findsNWidgets(2));
      await tester.tap(selectors.at(1));
      await tester.pumpAndSettle();
      expect(find.text('Meetup second'), findsOneWidget);
      await tester.tap(find.text('See post'));
      await tester.pumpAndSettle();
      expect(find.text('Opened second'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('joining a map event persists RSVP and offers its group chat', (
    tester,
  ) async {
    final repository = _EventRepository();
    final group = buildMapEventGroups(
      posts: [_event('join_me')],
      spots: [_spot],
      now: _now,
    ).single;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surfRepositoryProvider.overrideWithValue(repository),
          meProvider.overrideWith(
            (_) async => DemoSeed.me.copyWith(id: 'viewer'),
          ),
          mapEventEngagementProvider.overrideWith(
            (_) async => _engagement(repository.joined.toSet()),
          ),
          mapEventAttendeesProvider.overrideWith((_, _) async => []),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => FilledButton(
                  onPressed: () => showMapEventPopup(context, group),
                  child: const Text('Open event'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open event'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join now'));
    await tester.pumpAndSettle();
    expect(repository.requests, ['join_me']);
    expect(repository.joined, {'join_me'});
    expect(find.text('Join the event group chat?'), findsOneWidget);
    await tester.tap(find.text('Maybe later'));
    await tester.pumpAndSettle();
    expect(find.text('Going · tap to leave'), findsOneWidget);
    expect(find.text('Group chat'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
