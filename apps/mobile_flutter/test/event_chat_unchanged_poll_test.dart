import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/home/home_page.dart' show meProvider;
import 'package:mobile_flutter/features/social/chat_media_widgets.dart';
import 'package:mobile_flutter/features/social/direct_message_api.dart';
import 'package:mobile_flutter/features/social/event_chat_page.dart';

import 'auth_session_test.dart' show MemorySessions, FakeTransport, body;

const _eventId = 'unchanged-poll-event';

Map<String, dynamic> _message(
  String id,
  String text, {
  String author = 'Surf Guest',
  String? avatar,
  Map<String, dynamic>? attachment,
}) => {
  'id': id,
  'post_id': _eventId,
  'user_id': 'guest',
  'author_name': author,
  'author_handle': 'surfguest',
  'author_avatar_url': avatar,
  'text': text,
  'created_at': '2030-01-01T09:00:00Z',
  'client_message_id': 'client-$id',
  'attachment': ?attachment,
};

class _Repository extends SurfRepository {
  _Repository() : super(Dio(), DemoPersistence());
  @override
  Future<SocialPostModel> fetchSocialPost(String id) async =>
      SocialPostModel.fromJson({
        'id': _eventId,
        'user_id': 'owner',
        'author_name': 'Event Host',
        'author_handle': 'host',
        'post_type': 'surf_plan',
        'visibility': 'public',
        'body': 'Morning surf meetup',
        'media': <Map<String, dynamic>>[],
        'created_at': '2030-01-01T08:00:00Z',
      });
}

class _Fixture {
  _Fixture() {
    api = DirectMessageApi(
      Dio(BaseOptions(baseUrl: 'https://event-poll.fixture.invalid'))
        ..httpClientAdapter = FakeTransport((request) async {
          expect(request.headers['Authorization'], 'Bearer old-test-session');
          if (request.path == '/users/me') return body({'id': 'owner'});
          if (request.path == '/social/posts/$_eventId/chat/settings') {
            return body({
              'user_id': 'owner',
              'post_id': _eventId,
              'muted': false,
              'left': false,
            });
          }
          if (request.path == '/social/posts/$_eventId/chat') {
            expect(request.method, 'GET');
            reads++;
            return body(rows);
          }
          if (request.path == '/messages/media/capabilities') {
            return body({'enabled': false});
          }
          // Attachments are deliberately unavailable in this text/descriptor
          // equality fixture, so no image/video provider is ever contacted.
          return body({'detail': 'No private media in this fixture'}, 404);
        }),
      MemorySessions(),
    );
  }
  late final DirectMessageApi api;
  var rows = <Map<String, dynamic>>[_message('first', 'First surf message')];
  int reads = 0;

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          meProvider.overrideWith(
            (_) async => DemoSeed.me.copyWith(id: 'owner'),
          ),
          surfRepositoryProvider.overrideWithValue(_Repository()),
          directMessageApiProvider.overrideWithValue(api),
        ],
        child: const MaterialApp(home: EventChatPage(postId: _eventId)),
      ),
    );
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(tester.takeException(), isNull);
  }

  Future<void> poll(WidgetTester tester) async {
    final previous = reads;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(reads, previous + 1);
    expect(tester.takeException(), isNull);
  }

  Future<void> close(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  testWidgets(
    'identical five-second event poll preserves mounted message widget',
    (tester) async {
      final fixture = _Fixture();
      await fixture.mount(tester);
      final message = tester.widget<Text>(find.text('First surf message'));
      // The wire adapter serializes and parses again, so this is equal data,
      // not reusing a model/list instance from the previous request.
      fixture.rows = [Map<String, dynamic>.from(fixture.rows.single)];
      await fixture.poll(tester);
      expect(
        tester.widget<Text>(find.text('First surf message')),
        same(message),
        reason: 'Unchanged chat polling must not rebuild every message bubble',
      );
      await fixture.close(tester);
    },
  );

  for (final change in [
    'text',
    'author',
    'avatar',
    'attachment',
    'attachment_id',
    'media_type',
  ]) {
    testWidgets('same message ID still updates when $change changes', (
      tester,
    ) async {
      final fixture = _Fixture();
      if (change == 'media_type' || change == 'attachment_id') {
        fixture.rows = [
          _message(
            'first',
            'First surf message',
            attachment: {'id': 'private-photo', 'media_type': 'photo'},
          ),
        ];
      }
      await fixture.mount(tester);
      final before = tester.widget<Text>(find.text('First surf message'));
      final updated = Map<String, dynamic>.from(fixture.rows.single);
      switch (change) {
        case 'text':
          updated['text'] = 'Edited surf message';
        case 'author':
          updated['author_name'] = 'Updated Surfer';
        case 'avatar':
          updated['author_avatar_url'] =
              'https://avatar.fixture.invalid/new.jpg';
        case 'attachment':
          updated['attachment'] = {
            'id': 'private-photo',
            'media_type': 'photo',
          };
        case 'media_type':
          updated['attachment'] = {
            'id': 'private-photo',
            'media_type': 'video',
          };
        case 'attachment_id':
          updated['attachment'] = {
            'id': 'replacement-photo',
            'media_type': 'photo',
          };
      }
      fixture.rows = [updated];
      await fixture.poll(tester);
      expect(
        tester.widget<Text>(
          find.text(
            change == 'text' ? 'Edited surf message' : 'First surf message',
          ),
        ),
        isNot(same(before)),
        reason: 'The equality guard must include $change, not only message ID',
      );
      if (change == 'text') {
        expect(find.text('First surf message'), findsNothing);
      }
      if (change == 'author') {
        expect(find.text('Updated Surfer'), findsOneWidget);
      }
      if (change.startsWith('attachment') || change == 'media_type') {
        final bubble = tester.widget<ChatMediaBubble>(
          find.byType(ChatMediaBubble),
        );
        expect(
          bubble.attachment.id,
          change == 'attachment_id' ? 'replacement-photo' : 'private-photo',
        );
        expect(
          bubble.attachment.mediaType,
          change == 'media_type' ? 'video' : 'photo',
        );
      }
      await fixture.close(tester);
    });
  }

  testWidgets('event polls apply changed order, added messages and deletion', (
    tester,
  ) async {
    final fixture = _Fixture()
      ..rows = [
        _message('first', 'First surf message'),
        _message('second', 'Second surf message'),
      ];
    await fixture.mount(tester);
    expect(
      tester.getTopLeft(find.text('First surf message')).dy,
      lessThan(tester.getTopLeft(find.text('Second surf message')).dy),
    );
    fixture.rows = [fixture.rows[1], fixture.rows[0]];
    await fixture.poll(tester);
    expect(
      tester.getTopLeft(find.text('Second surf message')).dy,
      lessThan(tester.getTopLeft(find.text('First surf message')).dy),
    );
    fixture.rows = [...fixture.rows, _message('third', 'New surf message')];
    await fixture.poll(tester);
    expect(find.text('New surf message'), findsOneWidget);
    fixture.rows = [fixture.rows.last];
    await fixture.poll(tester);
    expect(find.text('First surf message'), findsNothing);
    expect(find.text('Second surf message'), findsNothing);
    expect(find.text('New surf message'), findsOneWidget);
    await fixture.close(tester);
  });
}
