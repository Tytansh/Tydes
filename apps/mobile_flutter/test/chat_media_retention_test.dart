import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/chat_media_api.dart';
import 'package:mobile_flutter/features/social/chat_media_widgets.dart';
import 'package:mobile_flutter/features/social/direct_message_api.dart';
import 'package:mobile_flutter/features/social/direct_messages_page.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

import 'auth_session_test.dart' show MemorySessions;

Map<String, dynamic> _message(
  String id, {
  String? attachment,
  String sender = 'bob',
}) => {
  'id': id,
  'sender_user_id': sender,
  'text': attachment == null ? id : '',
  'created_at': '2030-01-01T00:00:00Z',
  if (attachment != null)
    'attachment': {'id': attachment, 'media_type': 'photo'},
};

class _InboxApi extends DirectMessageApi {
  _InboxApi() : super(Dio(), MemorySessions());
  final sessions = <String, _InboxSession>{};
  @override
  Future<DirectMessageSession> openSession(String ownerId) async =>
      sessions.putIfAbsent(ownerId, () => _InboxSession(ownerId));
}

class _InboxSession extends DirectMessageSession {
  _InboxSession(String owner) : super(Dio(), MemorySessions(), owner, 'fake');
  final messages = <String, List<Map<String, dynamic>>>{
    'thread': [_message('received', attachment: 'received-photo')],
    'other': [_message('other-received', attachment: 'other-photo')],
  };
  int sequence = 0;
  bool muted = false;
  final pendingThreads = <String, Completer<Map<String, dynamic>>>{};
  @override
  Future<void> ensureCurrent() async {}
  Map<String, dynamic> _thread(String id, {bool full = true}) => {
    'id': id,
    'peer_user_id': 'bob',
    'peer_name': id == 'other' ? 'Other friend' : 'Bob',
    'peer_handle': 'bob',
    'request_accepted': true,
    'request_declined': false,
    'can_send_attachments': true,
    'muted': muted,
    'unread_count': 0,
    'updated_at': '2030-01-01T00:00:00Z',
    if (full) 'messages': jsonDecode(jsonEncode(messages[id]!)),
  };
  @override
  Future<List<Map<String, dynamic>>> threads() async => [
    _thread('thread', full: false),
    _thread('other', full: false),
  ];
  @override
  Future<Map<String, dynamic>> thread(String id) async =>
      pendingThreads[id]?.future ?? _thread(id);
  @override
  Future<int> markRead(String threadId, String messageId) async => 0;
  @override
  Future<Map<String, dynamic>> send({
    required String threadId,
    required String text,
    required String clientMessageId,
    String? sharedPostId,
    String? attachmentId,
  }) async {
    final message =
        _message(
            'sent-${++sequence}',
            attachment: attachmentId,
            sender: ownerId,
          )
          ..['text'] = text
          ..['client_message_id'] = clientMessageId;
    messages[threadId]!.add(message);
    return message;
  }
}

class _MediaApi extends ChatMediaApi {
  _MediaApi() : super(_InboxApi());
  final accessReads = <String, int>{};
  final failures = <String>{};
  @override
  Future<ChatMediaSession> session(
    String owner,
    String type,
    String id,
  ) async => _MediaSession(this, owner, type, id);
  String scope(String owner, String thread, String id) => '$owner/$thread/$id';
  int reads(String id, {String owner = 'alice', String thread = 'thread'}) =>
      accessReads[scope(owner, thread, id)] ?? 0;
}

class _MediaSession extends ChatMediaSession {
  _MediaSession(this.api, this.owner, String type, this.thread)
    : super(_InboxSession(owner), Dio(), type, thread);
  final _MediaApi api;
  final String owner, thread;
  @override
  Future<Map<String, dynamic>> access(String id) async {
    final scope = api.scope(owner, thread, id);
    final read = api.accessReads.update(
      scope,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    if (api.failures.contains(scope)) throw StateError('Access lease expired.');
    return {
      'id': id,
      'media_type': 'photo',
      'url': 'https://private.example.invalid/$scope/lease-$read.png',
      'expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 5))
          .toIso8601String(),
    };
  }
}

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
);

class _Images extends Fake implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _ImageRequest();
}

class _ImageRequest extends Fake implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _ImageResponse();
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  int get contentLength => _png.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_png).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  final inbox = _InboxApi();
  final media = _MediaApi();
  String owner = 'alice';
  late final container = ProviderContainer(
    overrides: [
      directMessageApiProvider.overrideWithValue(inbox),
      chatMediaApiProvider.overrideWithValue(media),
      meProvider.overrideWith((_) async => DemoSeed.me.copyWith(id: owner)),
      joinedEventChatsProvider.overrideWith((_) async => []),
      socialRelationshipHydrationProvider.overrideWith((_) async {}),
    ],
  );
  Future<void> show(WidgetTester tester, {String thread = 'thread'}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: DirectMessagesPage(initialThreadId: thread)),
      ),
    );
    await _pump(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
    debugNetworkImageHttpClientProvider = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}

Future<void> _pump(WidgetTester tester) async {
  for (var index = 0; index < 8; index++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Finder _bubble(String id) => find.byWidgetPredicate(
  (widget) => widget is ChatMediaBubble && widget.attachment.id == id,
);

void main() {
  setUp(() {
    debugNetworkImageHttpClientProvider = _Images.new;
  });
  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets(
    'sending text retains an already received photo and signed lease',
    (tester) async {
      final harness = _Harness();
      try {
        await harness.show(tester);
        final state = tester.state(_bubble('received-photo'));
        final image = tester.element(
          find.descendant(
            of: _bubble('received-photo'),
            matching: find.byType(Image),
          ),
        );
        expect(harness.media.reads('received-photo'), 1);
        await tester.enterText(
          find.byKey(const ValueKey('dm-message-input')),
          'A new reply',
        );
        await tester.tap(find.byKey(const ValueKey('dm-send-message')));
        await _pump(tester);
        expect(tester.state(_bubble('received-photo')), same(state));
        expect(
          tester.element(
            find.descendant(
              of: _bubble('received-photo'),
              matching: find.byType(Image),
            ),
          ),
          same(image),
        );
        expect(harness.media.reads('received-photo'), 1);
        expect(tester.takeException(), isNull);
      } finally {
        await harness.finish(tester);
      }
    },
  );

  testWidgets('sending a second photo retains the received photo', (
    tester,
  ) async {
    final harness = _Harness();
    try {
      await harness.show(tester);
      final state = tester.state(_bubble('received-photo'));
      await harness.container
          .read(directMessageThreadsProvider.notifier)
          .sendMediaMessage('thread', '', 'outgoing-photo');
      await _pump(tester);
      expect(tester.state(_bubble('received-photo')), same(state));
      expect(harness.media.reads('received-photo'), 1);
      expect(harness.media.reads('outgoing-photo'), 1);
      expect(tester.takeException(), isNull);
    } finally {
      await harness.finish(tester);
    }
  });

  testWidgets('unchanged polls and metadata updates retain existing media', (
    tester,
  ) async {
    final harness = _Harness();
    try {
      await harness.show(tester);
      final state = tester.state(_bubble('received-photo'));
      final notifier = harness.container.read(
        directMessageThreadsProvider.notifier,
      );
      for (var index = 0; index < 3; index++) {
        harness.inbox.sessions['alice']!.muted = index.isEven;
        await notifier.loadThread('thread');
        await _pump(tester);
        expect(tester.state(_bubble('received-photo')), same(state));
        expect(harness.media.reads('received-photo'), 1);
      }
      expect(tester.takeException(), isNull);
    } finally {
      await harness.finish(tester);
    }
  });

  testWidgets('new incoming content and older history retain visible photos', (
    tester,
  ) async {
    final harness = _Harness();
    try {
      await harness.show(tester);
      final state = tester.state(_bubble('received-photo'));
      final session = harness.inbox.sessions['alice']!;
      session.messages['thread']!.add(
        _message('new-incoming', attachment: 'new-photo'),
      );
      await harness.container
          .read(directMessageThreadsProvider.notifier)
          .loadThread('thread');
      await _pump(tester);
      expect(tester.state(_bubble('received-photo')), same(state));
      session.messages['thread']!.insert(0, _message('older history'));
      await harness.container
          .read(directMessageThreadsProvider.notifier)
          .loadThread('thread');
      await _pump(tester);
      expect(tester.state(_bubble('received-photo')), same(state));
      expect(harness.media.reads('received-photo'), 1);
      expect(harness.media.reads('new-photo'), 1);
      expect(tester.takeException(), isNull);
    } finally {
      await harness.finish(tester);
    }
  });

  testWidgets('an expired attachment retry reloads only its own lease', (
    tester,
  ) async {
    final harness = _Harness();
    try {
      await harness.show(tester);
      harness.inbox.sessions['alice']!.messages['thread']!.add(
        _message('second-received', attachment: 'second-photo'),
      );
      await harness.container
          .read(directMessageThreadsProvider.notifier)
          .loadThread('thread');
      await _pump(tester);
      final second = tester.state(_bubble('second-photo'));
      final scope = harness.media.scope('alice', 'thread', 'received-photo');
      harness.media.failures.add(scope);
      await tester.ensureVisible(_bubble('received-photo'));
      await _pump(tester);
      await tester.tap(_bubble('received-photo'));
      await _pump(tester);
      expect(
        find.descendant(
          of: _bubble('received-photo'),
          matching: find.text('Reload attachment'),
        ),
        findsOneWidget,
      );
      harness.media.failures.remove(scope);
      await tester.tap(
        find.descendant(
          of: _bubble('received-photo'),
          matching: find.text('Reload attachment'),
        ),
      );
      await _pump(tester);
      expect(harness.media.reads('received-photo'), 4);
      expect(harness.media.reads('second-photo'), 1);
      expect(tester.state(_bubble('second-photo')), same(second));
      expect(tester.takeException(), isNull);
    } finally {
      await harness.finish(tester);
    }
  });

  testWidgets('changing owner never reuses the previous account media state', (
    tester,
  ) async {
    final harness = _Harness();
    try {
      await harness.show(tester);
      final previous = tester.state(_bubble('received-photo'));
      harness.owner = 'carol';
      harness.container.invalidate(meProvider);
      await _pump(tester);
      expect(previous.mounted, isFalse);
      final bubbles = tester.widgetList<ChatMediaBubble>(
        find.byType(ChatMediaBubble),
      );
      expect(bubbles.every((widget) => widget.ownerId == 'carol'), isTrue);
      expect(harness.media.reads('received-photo'), 1);
      expect(tester.takeException(), isNull);
    } finally {
      await harness.finish(tester);
    }
  });

  testWidgets(
    'changing route conversation does not retain the old private photo',
    (tester) async {
      final harness = _Harness();
      try {
        await harness.show(tester);
        final previous = tester.state(_bubble('received-photo'));
        await harness.show(tester, thread: 'other');
        expect(_bubble('received-photo'), findsNothing);
        expect(_bubble('other-photo'), findsOneWidget);
        expect(previous.mounted, isFalse);
        expect(harness.media.reads('received-photo'), 1);
        expect(harness.media.reads('other-photo', thread: 'other'), 1);
        expect(tester.takeException(), isNull);
      } finally {
        await harness.finish(tester);
      }
    },
  );

  testWidgets('a late old route response cannot restore its private media', (
    tester,
  ) async {
    final harness = _Harness();
    final gate = Completer<Map<String, dynamic>>();
    try {
      await harness.show(tester);
      final session = harness.inbox.sessions['alice']!;
      session.pendingThreads['other'] = gate;
      await harness.show(tester, thread: 'other');
      await harness.show(tester, thread: 'thread');
      gate.complete(session._thread('other'));
      await _pump(tester);
      expect(_bubble('received-photo'), findsOneWidget);
      expect(_bubble('other-photo'), findsNothing);
      expect(
        tester
            .widget<ChatMediaBubble>(_bubble('received-photo'))
            .conversationId,
        'thread',
      );
      expect(tester.takeException(), isNull);
    } finally {
      if (!gate.isCompleted) gate.complete({'id': 'other', 'messages': []});
      await harness.finish(tester);
    }
  });
}
