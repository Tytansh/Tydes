import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/direct_message_api.dart';
import 'package:mobile_flutter/features/social/direct_messages_page.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

class _Memory extends DemoPersistence {
  _Memory(this.token);
  String? token;
  int legacyReads = 0;
  int legacyWrites = 0;
  @override
  Future<String?> loadAccessToken() async => token;
  @override
  Future<List<Map<String, dynamic>>> loadDirectMessageThreadPayloads() async {
    legacyReads++;
    return [
      {'id': 'another-account-local-message'},
    ];
  }

  @override
  Future<void> saveDirectMessageThreadPayloads(
    List<Map<String, dynamic>> rows,
  ) async {
    legacyWrites++;
  }
}

ResponseBody _response(Object body, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

class _Transport implements HttpClientAdapter {
  _Transport(this.handler);
  final Future<ResponseBody> Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);
  @override
  void close({bool force = false}) {}
}

/// A tiny wire-level server fixture shared by two independent client sessions.
/// No direct notifier mutation, persisted messages or real network is used.
class _Backend {
  final messages = <Map<String, dynamic>>[];
  final readIds = <String, Set<String>>{};
  final calls = <RequestOptions>[];
  bool exists = false;
  bool failSend = false;
  bool wrongAck = false;
  Completer<ResponseBody>? pendingSend;
  String threadId = 'dm_alice_bob';
  int _next = 0;

  String owner(RequestOptions request) =>
      (request.headers['Authorization'] as String).replaceFirst('Bearer ', '');
  String peer(String owner) => owner == 'alice' ? 'bob' : 'alice';
  int unread(String owner) => messages
      .where(
        (message) =>
            message['sender_user_id'] != owner &&
            !(readIds[owner] ?? {}).contains(message['id']),
      )
      .length;
  Map<String, dynamic> thread(String owner, {bool full = true}) => {
    'id': threadId,
    'peer_user_id': peer(owner),
    'peer_name': peer(owner) == 'bob' ? 'Bob' : 'Alice',
    'peer_handle': peer(owner),
    'peer_avatar_url': null,
    'peer_premium': false,
    'preview': messages.isEmpty ? '' : messages.last['text'],
    'updated_at': '2030-01-01T00:00:00Z',
    'unread_count': unread(owner),
    'request_accepted': true,
    'request_declined': false,
    if (full) 'messages': messages,
  };
  Map<String, dynamic> add(String sender, String text, String clientId) {
    exists = true;
    final existing = messages
        .where(
          (message) =>
              message['sender_user_id'] == sender &&
              message['client_message_id'] == clientId,
        )
        .firstOrNull;
    if (existing != null) return existing;
    final message = <String, dynamic>{
      'id': 'message_${++_next}',
      'sender_user_id': sender,
      'text': text,
      'client_message_id': clientId,
      'created_at': '2030-01-01T00:00:00Z',
    };
    messages.add(message);
    return message;
  }

  Future<ResponseBody> handle(RequestOptions request) async {
    calls.add(request);
    final user = owner(request);
    if (request.path == '/users/me') return _response({'id': user});
    if (request.path == '/messages/threads' && request.method == 'GET') {
      return _response({
        'threads': exists ? [thread(user, full: false)] : [],
      });
    }
    if (request.path == '/messages/threads' && request.method == 'POST') {
      exists = true;
      return _response(thread(user));
    }
    if (request.path == '/messages/threads/$threadId' &&
        request.method == 'GET') {
      return _response(thread(user));
    }
    if (request.path.endsWith('/messages')) {
      if (pendingSend != null) return pendingSend!.future;
      if (failSend) return _response({'detail': 'Temporary test outage'}, 503);
      final data = Map<String, dynamic>.from(request.data as Map);
      final message = add(
        user,
        data['text'] as String,
        data['client_message_id'] as String,
      );
      return _response(
        wrongAck
            ? {...message, 'sender_user_id': 'unrelated-account'}
            : message,
      );
    }
    if (request.path.endsWith('/read')) {
      final marker = (request.data as Map)['last_message_id'];
      for (final message in messages) {
        if (message['sender_user_id'] != user) {
          (readIds[user] ??= {}).add(message['id'] as String);
        }
        if (message['id'] == marker) break;
      }
      return _response({'thread_id': threadId, 'unread_count': unread(user)});
    }
    return _response({'detail': 'Unknown test route'}, 404);
  }

  DirectMessageApi api(_Memory memory) => DirectMessageApi(
    Dio(BaseOptions(baseUrl: 'https://test.invalid'))
      ..httpClientAdapter = _Transport(handle),
    memory,
  );
}

Future<DirectMessageThreadsNotifier> _controller(
  _Backend backend,
  _Memory memory, {
  VoidCallback? onCountsChanged,
}) async {
  final ready = Completer<void>();
  final controller = DirectMessageThreadsNotifier(
    api: backend.api(memory),
    ownerId: memory.token,
    onStatus: (status) {
      if (!status.isLoading && !ready.isCompleted) ready.complete();
    },
    onCountsChanged: onCountsChanged ?? () {},
  );
  await ready.future;
  return controller;
}

void main() {
  test(
    'two separate account clients exchange confirmed messages and count 12 inbound messages',
    () async {
      final backend = _Backend();
      final aliceMemory = _Memory('alice');
      final bobMemory = _Memory('bob');
      final alice = await _controller(backend, aliceMemory);
      final bob = await _controller(backend, bobMemory);
      addTearDown(alice.dispose);
      addTearDown(bob.dispose);
      await alice.ensureThreadForProfile(
        const PublicProfilePreview(
          userId: 'bob',
          displayName: 'Bob',
          handle: 'bob',
        ),
      );
      for (var i = 0; i < 12; i++) {
        await alice.sendMessage(backend.threadId, 'Surf message $i');
      }
      await bob.refresh();
      expect(bob.state.single.unreadCount, 12);
      expect(alice.state.single.unreadCount, 0);
      await bob.loadThread(backend.threadId);
      expect(bob.state.single.messages.length, 12);
      expect(
        bob.state.single.messages.every((message) => !message.isMe),
        isTrue,
      );
      await bob.markRead(backend.threadId);
      expect(bob.state.single.unreadCount, 0);
      expect(backend.unread('bob'), 0);
      await alice.loadThread(backend.threadId);
      expect(
        alice.state.single.messages.every((message) => message.isMe),
        isTrue,
      );
      expect(aliceMemory.legacyReads + bobMemory.legacyReads, 0);
      expect(aliceMemory.legacyWrites + bobMemory.legacyWrites, 0);
    },
  );

  test(
    'pending and failed send never append and retry reuses its idempotency key',
    () async {
      final backend = _Backend()..exists = true;
      final controller = await _controller(backend, _Memory('alice'));
      addTearDown(controller.dispose);
      final pending = Completer<ResponseBody>();
      backend.pendingSend = pending;
      final send = controller.sendMessage(backend.threadId, 'Keep this draft');
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.single.messages, isEmpty);
      await expectLater(
        controller.sendMessage(backend.threadId, 'Keep this draft'),
        throwsStateError,
      );
      final failed = expectLater(send, throwsA(isA<DioException>()));
      pending.complete(_response({'detail': 'Try later'}, 503));
      await failed;
      expect(controller.state.single.messages, isEmpty);
      final firstKey = (backend.calls.last.data as Map)['client_message_id'];
      backend.pendingSend = null;
      await controller.sendMessage(backend.threadId, 'Keep this draft');
      final secondKey = (backend.calls.last.data as Map)['client_message_id'];
      expect(secondKey, firstKey);
      expect(controller.state.single.messages.single.text, 'Keep this draft');
      expect(backend.messages.length, 1);
    },
  );

  test('read marker leaves a newer unseen incoming message unread', () async {
    final backend = _Backend();
    backend.add('alice', 'Already loaded', 'initial');
    final controller = await _controller(backend, _Memory('bob'));
    addTearDown(controller.dispose);
    await controller.loadThread(backend.threadId);
    backend.add('alice', 'Arrived after the loaded page', 'later');
    await controller.markRead(backend.threadId);
    expect(controller.state.single.unreadCount, 1);
    expect(backend.unread('bob'), 1);
  });

  test('wrong sender acknowledgement cannot fabricate a sent bubble', () async {
    final backend = _Backend()
      ..exists = true
      ..wrongAck = true;
    final controller = await _controller(backend, _Memory('alice'));
    addTearDown(controller.dispose);
    await expectLater(
      controller.sendMessage(backend.threadId, 'hello'),
      throwsStateError,
    );
    expect(controller.state.single.messages, isEmpty);
  });

  test(
    'switching the stored account rejects an in-flight inbox response',
    () async {
      final memory = _Memory('alice');
      final pending = Completer<ResponseBody>();
      var verified = false;
      final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
        ..httpClientAdapter = _Transport((request) async {
          if (request.path == '/users/me') {
            verified = true;
            return _response({'id': 'alice'});
          }
          expect(request.headers['Authorization'], 'Bearer alice');
          return pending.future;
        });
      final session = await DirectMessageApi(dio, memory).openSession('alice');
      expect(verified, isTrue);
      final read = session.threads();
      await Future<void>.delayed(Duration.zero);
      memory.token = 'bob';
      final rejected = expectLater(read, throwsStateError);
      pending.complete(
        _response({
          'threads': [
            {'id': 'private-bob-thread'},
          ],
        }),
      );
      await rejected;
    },
  );

  test(
    'an owner/token mismatch is rejected before any inbox is loaded',
    () async {
      final backend = _Backend();
      await expectLater(
        backend.api(_Memory('bob')).openSession('alice'),
        throwsStateError,
      );
      expect(backend.calls.length, 1);
    },
  );

  test(
    'private local-file attachments explicitly fail instead of pretending delivery',
    () async {
      final backend = _Backend()..exists = true;
      final controller = await _controller(backend, _Memory('alice'));
      addTearDown(controller.dispose);
      await expectLater(
        controller.sendAttachment(
          threadId: backend.threadId,
          path: '/private/photo.jpg',
          type: 'image',
        ),
        throwsStateError,
      );
      expect(
        backend.calls.where((request) => request.method == 'POST'),
        isEmpty,
      );
    },
  );

  testWidgets(
    'failed chat send preserves the draft, then confirmed retry clears it',
    (tester) async {
      final backend = _Backend()
        ..exists = true
        ..failSend = true;
      final memory = _Memory('alice');
      final container = ProviderContainer(
        overrides: [
          directMessageApiProvider.overrideWithValue(backend.api(memory)),
          meProvider.overrideWith(
            (_) async => DemoSeed.me.copyWith(id: 'alice'),
          ),
          joinedEventChatsProvider.overrideWith((_) async => []),
          socialRelationshipHydrationProvider.overrideWith((_) async {}),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: DirectMessagesPage(
              initialThreadId: backend.threadId,
              seedProfile: const PublicProfilePreview(
                userId: 'bob',
                displayName: 'Bob',
                handle: 'bob',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('dm-message-input')),
        'Actual draft',
      );
      await tester.tap(find.byKey(const ValueKey('dm-send-message')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Message not sent.'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('dm-message-input')))
            .controller!
            .text,
        'Actual draft',
      );
      expect(backend.messages, isEmpty);
      backend.failSend = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('dm-message-input')))
            .controller!
            .text,
        isEmpty,
      );
      expect(backend.messages.single['text'], 'Actual draft');
      expect(
        container.read(directMessageThreadsProvider).single.messages.length,
        1,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account switch cannot display the previous account\'s composer draft',
    (tester) async {
      final backend = _Backend()..exists = true;
      final memory = _Memory('alice');
      var ownerId = 'alice';
      final container = ProviderContainer(
        overrides: [
          directMessageApiProvider.overrideWithValue(backend.api(memory)),
          meProvider.overrideWith(
            (_) async => DemoSeed.me.copyWith(id: ownerId),
          ),
          joinedEventChatsProvider.overrideWith((_) async => []),
          socialRelationshipHydrationProvider.overrideWith((_) async {}),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: DirectMessagesPage(
              initialThreadId: backend.threadId,
              seedProfile: const PublicProfilePreview(
                userId: 'bob',
                displayName: 'Bob',
                handle: 'bob',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('dm-message-input')),
        'Private Alice draft',
      );
      memory.token = 'bob';
      ownerId = 'bob';
      container.invalidate(meProvider);
      await tester.pumpAndSettle();
      expect(
        container.read(directMessageThreadsProvider.notifier).ownerId,
        'bob',
      );
      // The wrapper can recreate this conversation for Bob, or remove it while
      // Bob's inbox loads. Either way, no Alice draft may survive the switch.
      expect(find.text('Private Alice draft'), findsNothing);
      final composer = find.byKey(const ValueKey('dm-message-input'));
      if (composer.evaluate().isNotEmpty) {
        expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
