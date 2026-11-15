import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/direct_message_api.dart';
import 'package:mobile_flutter/features/social/direct_messages_page.dart';

import 'auth_session_test.dart' show MemorySessions;

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

Map<String, dynamic> _message(String id, String text) => {
  'id': id,
  'sender_user_id': 'bob',
  'text': text,
  'created_at': '2020-01-01T00:00:00Z',
};

class _PollSession extends DirectMessageSession {
  _PollSession()
    : super(Dio(), MemorySessions(), 'alice', 'synthetic-test-token');

  Map<String, dynamic> snapshot = {
    'id': 'thread',
    'peer_user_id': 'bob',
    'peer_name': 'Bob',
    'peer_handle': 'bob',
    'peer_avatar_url': null,
    'peer_premium': false,
    'preview': 'Surf tomorrow',
    'updated_at': '2020-01-01T00:00:00Z',
    'unread_count': 0,
    'request_accepted': true,
    'request_declined': false,
    'can_send_attachments': true,
    'messages': [_message('m1', 'Surf tomorrow')],
  };
  bool failInbox = false;
  List<Map<String, dynamic>>? inbox;
  @override
  Future<void> ensureCurrent() async {}
  @override
  Future<List<Map<String, dynamic>>> threads() async {
    if (failInbox) throw StateError('Temporary fixture outage');
    return (inbox ?? [snapshot])
        .map(
          (item) => _copy(item)
            ..remove('messages')
            ..remove('can_send_attachments'),
        )
        .toList();
  }

  @override
  Future<Map<String, dynamic>> thread(String threadId) async => _copy(snapshot);
}

class _PollApi extends DirectMessageApi {
  _PollApi(this.session) : super(Dio(), MemorySessions());
  final _PollSession session;
  @override
  Future<DirectMessageSession> openSession(String ownerId) async => session;
}

Future<DirectMessageThreadsNotifier> _controller(
  _PollSession session, {
  void Function(bool loading, bool error)? onStatus,
}) async {
  final ready = Completer<void>();
  final controller = DirectMessageThreadsNotifier(
    api: _PollApi(session),
    ownerId: 'alice',
    onStatus: (status) {
      onStatus?.call(status.isLoading, status.hasError);
      if (!status.isLoading && !ready.isCompleted) ready.complete();
    },
    onCountsChanged: () {},
  );
  await ready.future;
  addTearDown(controller.dispose);
  await controller.loadThread('thread');
  return controller;
}

void main() {
  test(
    'unchanged background inbox polls are quiet but recover errors',
    () async {
      final session = _PollSession();
      final status = <(bool, bool)>[];
      final controller = await _controller(
        session,
        onStatus: (loading, error) => status.add((loading, error)),
      );
      status.clear();
      var notifications = 0;
      final cancel = controller.addListener(
        (_) => notifications++,
        fireImmediately: false,
      );
      addTearDown(cancel);
      await controller.refresh(background: true);
      expect(notifications, 0);
      expect(status, isEmpty);
      session.failInbox = true;
      await expectLater(controller.refresh(background: true), throwsStateError);
      expect(status, [(false, true)]);
      session.failInbox = false;
      await controller.refresh(background: true);
      expect(status, [(false, true), (false, false)]);
      await controller.refresh(background: true);
      expect(status.length, 2);
      expect(notifications, 0);
      // Explicit user refresh still exposes refresh status and clears it.
      await controller.refresh();
      expect(status.sublist(2), [(true, false), (false, false)]);
    },
  );

  test('inbox polls retain server order, additions and removals', () async {
    final session = _PollSession();
    final controller = await _controller(session);
    final second = _copy(session.snapshot)
      ..['id'] = 'thread-2'
      ..['peer_user_id'] = 'charlie'
      ..['peer_handle'] = 'charlie';
    final orders = <List<String>>[];
    final cancel = controller.addListener(
      (threads) => orders.add(threads.map((thread) => thread.id).toList()),
      fireImmediately: false,
    );
    addTearDown(cancel);
    session.inbox = [session.snapshot, second];
    await controller.refresh(background: true);
    session.inbox = [second, session.snapshot];
    await controller.refresh(background: true);
    await controller.refresh(background: true);
    session.inbox = [second];
    await controller.refresh(background: true);
    expect(orders, [
      ['thread', 'thread-2'],
      ['thread-2', 'thread'],
      ['thread-2'],
    ]);
  });

  test(
    'twelve unchanged direct-chat polls publish zero thread updates',
    () async {
      final session = _PollSession();
      final controller = await _controller(session);
      final original = controller.threadByIdOrHandle('thread')!;
      var notifications = 0;
      final cancel = controller.addListener(
        (_) => notifications++,
        fireImmediately: false,
      );
      addTearDown(cancel);
      for (var index = 0; index < 12; index++) {
        await controller.loadThread('thread');
      }
      expect(
        notifications,
        0,
        reason:
            'One minute of identical visible polls must not rebuild chat rows.',
      );
      expect(controller.threadByIdOrHandle('thread'), same(original));
      expect(
        controller.threadByIdOrHandle('thread')!.messages.first,
        same(original.messages.first),
      );
    },
  );

  test(
    'direct polls retain all changed receipt, consent and profile fields',
    () async {
      final session = _PollSession();
      final controller = await _controller(session);
      for (final change in <String, dynamic>{
        'peer_name': 'Robert',
        'peer_handle': 'robert',
        'peer_avatar_url': 'https://example.invalid/new-avatar.png',
        'peer_premium': true,
        'preview': 'A changed preview',
        'updated_at': '2020-01-02T00:00:00Z',
        'unread_count': 12,
        'request_accepted': false,
        'request_declined': true,
        'can_send_attachments': false,
      }.entries) {
        final previous = controller.threadByIdOrHandle('thread');
        session.snapshot[change.key] = change.value;
        await controller.loadThread('thread');
        expect(
          controller.threadByIdOrHandle('thread'),
          isNot(same(previous)),
          reason: change.key,
        );
      }
      final changed = controller.threadByIdOrHandle('thread')!;
      expect(changed.name, 'Robert');
      expect(changed.handle, 'robert');
      expect(changed.avatarUrl, 'https://example.invalid/new-avatar.png');
      expect(changed.premium, isTrue);
      expect(changed.preview, 'A changed preview');
      expect(changed.unreadCount, 12);
      expect(changed.requestAccepted, isFalse);
      expect(changed.requestDeclined, isTrue);
      expect(changed.canSendAttachments, isFalse);
      // Summary responses omit mutual consent and messages. They must preserve
      // the last authorized full-thread values, not reset them on inbox polling.
      final messages = changed.messages;
      await controller.refresh();
      expect(
        controller.threadByIdOrHandle('thread')!.canSendAttachments,
        isFalse,
      );
      expect(controller.threadByIdOrHandle('thread')!.messages, same(messages));
    },
  );

  test(
    'direct polls apply same-ID edits, attachment changes, ordering and deletion',
    () async {
      final session = _PollSession();
      final controller = await _controller(session);
      final first = _message('m1', 'Edited same ID');
      session.snapshot['messages'] = [first];
      await controller.loadThread('thread');
      expect(
        controller.threadByIdOrHandle('thread')!.messages.single.text,
        'Edited same ID',
      );
      first['attachment'] = {'id': 'private-photo', 'media_type': 'photo'};
      await controller.loadThread('thread');
      expect(
        controller.threadByIdOrHandle('thread')!.messages.single.attachment!.id,
        'private-photo',
      );
      first['attachment'] = {'id': 'private-video', 'media_type': 'video'};
      await controller.loadThread('thread');
      expect(
        controller
            .threadByIdOrHandle('thread')!
            .messages
            .single
            .attachment!
            .mediaType,
        'video',
      );
      session.snapshot['messages'] = [first, _message('m2', 'New message')];
      await controller.loadThread('thread');
      expect(
        controller
            .threadByIdOrHandle('thread')!
            .messages
            .map((message) => message.id),
        ['m1', 'm2'],
      );
      session.snapshot['messages'] = [_message('m2', 'New message'), first];
      await controller.loadThread('thread');
      expect(
        controller
            .threadByIdOrHandle('thread')!
            .messages
            .map((message) => message.id),
        ['m2', 'm1'],
      );
      session.snapshot['messages'] = [_message('m2', 'New message')];
      await controller.loadThread('thread');
      expect(controller.threadByIdOrHandle('thread')!.messages.single.id, 'm2');
    },
  );

  test(
    'same-ID shared post edits and author/media updates still apply',
    () async {
      final session = _PollSession();
      final controller = await _controller(session);
      final post = <String, dynamic>{
        'id': 'shared-post',
        'user_id': 'author',
        'author_name': 'Original author',
        'author_handle': 'author',
        'author_avatar_url': null,
        'author_premium': false,
        'spot_id': 'old-spot',
        'post_type': 'general',
        'body': 'Original post',
        'media': [
          {
            'id': 'media',
            'media_type': 'photo',
            'url': 'https://example.invalid/old.png',
            'thumbnail_url': '',
          },
        ],
        'created_at': '2020-01-01T00:00:00Z',
      };
      session.snapshot['messages'] = [
        _message('m1', '')
          ..addAll({'shared_post_id': 'shared-post', 'shared_post': post}),
      ];
      await controller.loadThread('thread');
      for (final change in <String, dynamic>{
        'author_name': 'New author name',
        'author_handle': 'newhandle',
        'author_avatar_url': 'https://example.invalid/avatar.png',
        'author_premium': true,
        'spot_id': 'new-spot',
        'post_type': 'surf_plan',
        'body': 'Edited shared post',
        'media': [
          {
            'id': 'media',
            'media_type': 'photo',
            'url': 'https://example.invalid/new.png',
            'thumbnail_url': '',
          },
        ],
      }.entries) {
        final previous = controller
            .threadByIdOrHandle('thread')!
            .messages
            .single;
        post[change.key] = change.value;
        await controller.loadThread('thread');
        expect(
          controller.threadByIdOrHandle('thread')!.messages.single,
          isNot(same(previous)),
          reason: change.key,
        );
      }
      final message = controller.threadByIdOrHandle('thread')!.messages.single;
      expect(message.sharedPostBody, 'Edited shared post');
      expect(message.sharedPostAuthor, 'New author name');
      expect(message.sharedPostMediaUrl, 'https://example.invalid/new.png');
    },
  );
}
