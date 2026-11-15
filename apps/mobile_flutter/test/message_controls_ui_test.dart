import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/features/home/home_page.dart' show meProvider;
import 'package:mobile_flutter/features/social/direct_message_api.dart';
import 'package:mobile_flutter/features/social/direct_messages_page.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

import 'auth_session_test.dart' show MemorySessions, FakeTransport, body;

class _Fixture {
  _Fixture() {
    api = DirectMessageApi(
      Dio(BaseOptions(baseUrl: 'https://controls.fixture.invalid'))
        ..httpClientAdapter = FakeTransport((request) async {
          if (request.path == '/users/me') return body({'id': 'alice'});
          if (request.path == '/messages/threads') {
            return body({
              'threads': deleted ? [] : [snapshot(full: false)],
            });
          }
          if (request.path == '/messages/threads/thread/settings') {
            changes++;
            if (fail) return body({'detail': 'Synthetic failure'}, 503);
            muted = (request.data as Map)['muted'] as bool;
            return body({'user_id': 'alice', ...snapshot()});
          }
          if (request.path == '/messages/threads/thread' &&
              request.method == 'DELETE') {
            deletes++;
            if (fail) return body({'detail': 'Synthetic failure'}, 503);
            if (deleteGate != null) return deleteGate!.future;
            deleted = true;
            return body({
              'user_id': 'alice',
              'thread_id': 'thread',
              'deleted': true,
            });
          }
          if (request.path == '/messages/threads/thread') {
            if (pollGate != null) return pollGate!.future;
            return body(snapshot());
          }
          return body({'detail': 'Synthetic unavailable route'}, 404);
        }),
      memory,
    );
  }
  final memory = MemorySessions();
  late final DirectMessageApi api;
  bool muted = false, deleted = false, fail = false;
  int changes = 0, deletes = 0;
  Completer<ResponseBody>? deleteGate, pollGate;
  Map<String, dynamic> snapshot({bool full = true}) => {
    'id': 'thread',
    'peer_user_id': 'bob',
    'peer_name': 'Bob',
    'peer_handle': 'bob',
    'preview': 'Surf tomorrow',
    'updated_at': '2020-01-01T00:00:00Z',
    'request_accepted': true,
    'request_declined': false,
    'muted': muted,
    'unread_count': 0,
    if (full) 'messages': <Map<String, dynamic>>[],
    if (full) 'can_send_attachments': true,
  };
  Future<ProviderContainer> mount(
    WidgetTester tester, {
    bool eventFailure = false,
  }) async {
    final container = ProviderContainer(
      overrides: [
        directMessageApiProvider.overrideWithValue(api),
        meProvider.overrideWith(
          (_) async => DemoSeed.me.copyWith(id: 'alice', emailVerified: true),
        ),
        socialRelationshipHydrationProvider.overrideWith((_) async {}),
        joinedEventChatsProvider.overrideWith((_) async {
          if (eventFailure) throw StateError('Synthetic event outage');
          return [
            JoinedEventChatSummary(
              postId: 'event',
              title: 'Sunrise event',
              hostName: 'Host',
              meetupDate: null,
              sortDate: DateTime(2030),
            ),
          ];
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(meProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DirectMessagesPage()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> menu(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('dm-controls-thread')));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets(
    'Primary and Requests stay above event chats including event errors/search',
    (tester) async {
      final fixture = _Fixture();
      await fixture.mount(tester);
      expect(
        tester.getTopLeft(find.text('Primary')).dy,
        lessThan(tester.getTopLeft(find.text('Event chats')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Requests')).dy,
        lessThan(tester.getTopLeft(find.text('Event chats')).dy),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.mount(tester, eventFailure: true);
      await tester.enterText(
        find.byType(TextField),
        'No matching conversation',
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Primary')).dy,
        lessThan(tester.getTopLeft(find.text('Could not load event chats')).dy),
      );
      expect(find.text('Requests'), findsOneWidget);
    },
  );

  testWidgets(
    'row mute persists after confirmed ACK and failed unmute keeps preference',
    (tester) async {
      final fixture = _Fixture();
      final container = await fixture.mount(tester);
      await fixture.menu(tester);
      await tester.tap(find.text('Mute chat'));
      await tester.pumpAndSettle();
      expect(container.read(directMessageThreadsProvider).single.muted, isTrue);
      await fixture.menu(tester);
      expect(find.text('Unmute chat'), findsOneWidget);
      fixture.fail = true;
      await tester.tap(find.text('Unmute chat'));
      await tester.pumpAndSettle();
      expect(container.read(directMessageThreadsProvider).single.muted, isTrue);
      expect(fixture.changes, 2);
      expect(find.textContaining('Synthetic failure'), findsOneWidget);
      final roundTrip = DirectMessageThread.fromJson(
        container.read(directMessageThreadsProvider).single.toJson(),
      );
      expect(roundTrip.muted, isTrue);
      expect(roundTrip.copyWith(preview: 'New preview').muted, isTrue);
    },
  );

  testWidgets(
    'Delete chat confirms only-for-you wording and Cancel sends no request',
    (tester) async {
      final fixture = _Fixture();
      await fixture.mount(tester);
      await fixture.menu(tester);
      await tester.tap(find.text('Delete chat'));
      await tester.pumpAndSettle();
      expect(find.text('Delete chat for you?'), findsOneWidget);
      expect(
        find.textContaining('The other person keeps their copy'),
        findsOneWidget,
      );
      expect(
        find.textContaining('New messages will make the chat appear again'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fixture.deletes, 0);
      expect(find.text('Bob'), findsOneWidget);
    },
  );

  testWidgets(
    'Delete keeps its row while pending and removes it only after ACK',
    (tester) async {
      final fixture = _Fixture()..deleteGate = Completer<ResponseBody>();
      final container = await fixture.mount(tester);
      await fixture.menu(tester);
      await tester.tap(find.text('Delete chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete chat'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Bob'), findsOneWidget);
      final menu = tester.widget<PopupMenuButton>(
        find.byKey(const ValueKey('dm-controls-thread')),
      );
      expect(menu.enabled, isFalse);
      fixture.deleteGate!.complete(
        body({'user_id': 'alice', 'thread_id': 'thread', 'deleted': true}),
      );
      await tester.pumpAndSettle();
      expect(container.read(directMessageThreadsProvider), isEmpty);
      expect(find.text('Bob'), findsNothing);
    },
  );

  testWidgets(
    'failed Delete preserves row and chat controls are available inside conversation',
    (tester) async {
      final fixture = _Fixture()..fail = true;
      await fixture.mount(tester);
      await fixture.menu(tester);
      await tester.tap(find.text('Delete chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete chat'));
      await tester.pumpAndSettle();
      expect(find.text('Bob'), findsOneWidget);
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      expect(find.text('Mute chat'), findsOneWidget);
      expect(find.text('Delete chat'), findsOneWidget);
      expect(find.text('Report conversation'), findsOneWidget);
    },
  );

  test('queued old poll cannot restore a deleted chat', () async {
    final fixture = _Fixture();
    final ready = Completer<void>();
    final controller = DirectMessageThreadsNotifier(
      api: fixture.api,
      ownerId: 'alice',
      onStatus: (status) {
        if (!status.isLoading && !ready.isCompleted) ready.complete();
      },
      onCountsChanged: () {},
    );
    addTearDown(controller.dispose);
    await ready.future;
    fixture.pollGate = Completer<ResponseBody>();
    final old = controller.loadThread('thread');
    final oldFailure = expectLater(old, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    await controller.deleteChat('thread');
    fixture.pollGate!.complete(body(fixture.snapshot()));
    await oldFailure;
    expect(controller.threadByIdOrHandle('thread'), isNull);
  });
}
