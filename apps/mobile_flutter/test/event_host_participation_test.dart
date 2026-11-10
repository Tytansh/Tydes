import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/social/direct_messages_page.dart';
import 'package:mobile_flutter/features/social/event_chat_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

SocialPostModel _post({int guests = 0}) => SocialPostModel(
  id: 'hosted-event',
  userId: 'owner',
  authorName: 'Event Host',
  authorHandle: 'host',
  authorAvatarUrl: null,
  authorPremium: false,
  spotId: null,
  postType: 'surf_plan',
  visibility: 'public',
  body: 'Morning surf',
  media: const [],
  meetupDate: '2030-01-01',
  createdAt: '2026-01-01T12:00:00Z',
  rsvpCount: guests,
);

class _Repository extends SurfRepository {
  _Repository() : super(Dio(), DemoPersistence());
  final requests = <String>[];
  @override
  Future<List<SocialPostModel>> fetchEventChatPosts() async {
    requests.add('inbox');
    return [_post()];
  }

  @override
  Future<List<SocialPostModel>> fetchSocialPosts() =>
      throw StateError('Do not limit event chats to the recent feed');
  @override
  Future<SocialPostModel> fetchSocialPost(String id) async {
    requests.add('post:$id');
    return _post();
  }

  @override
  Future<UserProfile> fetchMe() async => DemoSeed.me.copyWith(id: 'owner');
  @override
  Future<List<EventChatMessageModel>> fetchEventChat(String postId) async => [];
  @override
  Future<List<EventAttendeeModel>> fetchEventAttendees(String postId) async => [
    const EventAttendeeModel(
      userId: 'owner',
      displayName: 'Event Host',
      handle: 'host',
      avatarUrl: null,
      premium: false,
      organizer: true,
    ),
    const EventAttendeeModel(
      userId: 'guest',
      displayName: 'Real Guest',
      handle: 'guest',
      avatarUrl: null,
      premium: false,
      organizer: false,
    ),
  ];
}

void main() {
  for (final alreadyRsvped in [false, true]) {
    testWidgets(
      'host is automatically in and counted once; stored RSVP $alreadyRsvped',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentViewerProvider.overrideWith(
                (_) async => DemoSeed.me.copyWith(id: 'owner'),
              ),
              surfInviteRsvpProvider.overrideWith(
                (_) => alreadyRsvped ? {'hosted-event'} : {},
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SurfInviteActions(post: _post(), spot: null),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('1 surfer in'), findsOneWidget);
        expect(find.text('2 surfers in'), findsNothing);
        expect(find.text('I’m in'), findsNothing);
        final button = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'You’re in'),
        );
        expect(button.onPressed, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'event count and attendee list use real guests without duplicating the host',
    (tester) async {
      final repository = _Repository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            surfRepositoryProvider.overrideWithValue(repository),
            currentViewerProvider.overrideWith(
              (_) async => DemoSeed.me.copyWith(id: 'owner'),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SurfInviteActions(post: _post(guests: 1), spot: null),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 surfers in'), findsOneWidget);
      await tester.tap(find.text('Who’s going'));
      await tester.pumpAndSettle();
      expect(find.text('Event Host'), findsOneWidget);
      expect(find.text('Real Guest'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hosted room appears automatically in Messages without RSVP or recent-feed lookup',
    (tester) async {
      final repository = _Repository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [surfRepositoryProvider.overrideWithValue(repository)],
          child: const MaterialApp(home: DirectMessagesPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Morning surf'), findsOneWidget);
      expect(find.text('Event group chat • Event Host'), findsOneWidget);
      expect(repository.requests, ['inbox']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty hosted chat opens even when event is not in latest feed posts',
    (tester) async {
      final repository = _Repository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [surfRepositoryProvider.overrideWithValue(repository)],
          child: const MaterialApp(home: EventChatPage(postId: 'hosted-event')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Morning surf'), findsOneWidget);
      expect(repository.requests, ['post:hosted-event']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
