import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:mobile_flutter/core/network/chat_media_models.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/features/home/home_page.dart' show meProvider;
import 'package:mobile_flutter/features/social/chat_media_api.dart';
import 'package:mobile_flutter/features/social/chat_media_widgets.dart';
import 'package:mobile_flutter/features/social/direct_message_api.dart';
import 'auth_session_test.dart' show MemorySessions;

class _VideoPlatform extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{};
  final playing = <int>{};
  final volumes = <int, double>{};
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = events.length;
    events[id] = StreamController<VideoEvent>()
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 2),
          size: const Size(640, 360),
        ),
      );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;
  @override
  Future<void> play(int playerId) async {
    playing.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {
    playing.remove(playerId);
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    volumes[playerId] = volume;
  }

  @override
  Future<void> dispose(int playerId) async {
    playing.remove(playerId);
  }

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.black);
}

class _MediaApi extends ChatMediaApi {
  _MediaApi(this.fake) : super(DirectMessageApi(Dio(), MemorySessions()));
  final _MediaSession fake;
  @override
  Future<ChatMediaSession> session(
    String owner,
    String type,
    String id,
  ) async => fake;
}

class _MediaSession extends ChatMediaSession {
  _MediaSession()
    : super(
        DirectMessageSession(
          Dio(),
          MemorySessions(),
          'alice',
          'old-test-session',
        ),
        Dio(),
        'direct',
        'thread',
      );
  ChatMediaCapabilities caps = const ChatMediaCapabilities(
    enabled: true,
    photosEnabled: true,
    videosEnabled: true,
  );
  int uploadCount = 0, capabilityReads = 0;
  final canceled = <String>[];
  Completer<ChatMediaAttachment>? pending;
  Completer<void>? reservationGate;
  bool failUpload = false;
  @override
  Future<Map<String, dynamic>> access(String id) async => {
    'id': id,
    'media_type': 'photo',
    'url': 'https://private.example.invalid/$id.png',
  };
  @override
  Future<ChatMediaCapabilities> capabilities() async {
    capabilityReads++;
    return caps;
  }

  @override
  Future<void> cancel(String id) async {
    canceled.add(id);
  }

  @override
  Future<ChatMediaAttachment> upload(
    XFile file,
    String mediaType, {
    required CancelToken cancellation,
    required void Function(String) onReservation,
    required void Function(double?) onProgress,
  }) async {
    final n = ++uploadCount;
    await reservationGate?.future;
    onReservation('reservation-$n');
    onProgress(0.25);
    if (failUpload) throw StateError('Upload failed. Try again.');
    return pending?.future ??
        Future.value(
          ChatMediaAttachment(id: 'attachment-$n', mediaType: mediaType),
        );
  }
}

class _NamedPhoto extends XFile {
  _NamedPhoto()
    : super.fromData(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
        ),
        mimeType: 'image/png',
      );
  @override
  String get name => 'chosen-photo.png';
}

XFile _photo() => _NamedPhoto();

Future<ProviderContainer> _show(
  WidgetTester tester,
  _MediaSession session,
  TextEditingController controller,
  Future<void> Function(String, String?) send, {
  bool allowed = true,
  Widget Function(Widget)? host,
  void Function()? onPick,
}) async {
  final container = ProviderContainer(
    overrides: [
      chatMediaApiProvider.overrideWithValue(_MediaApi(session)),
      chatMediaPickerProvider.overrideWithValue(() async {
        onPick?.call();
        return _photo();
      }),
    ],
  );
  addTearDown(container.dispose);
  final composer = ChatMessageComposer(
    ownerId: 'alice',
    conversationType: 'direct',
    conversationId: 'thread',
    controller: controller,
    onSend: send,
    attachmentsAllowed: allowed,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body:
              host?.call(composer) ??
              Align(alignment: Alignment.bottomCenter, child: composer),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _pick(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Add photo or video'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'private thumbnail and viewer hide while account change is pending',
    (tester) async {
      Completer<UserProfile>? replacement;
      final container = ProviderContainer(
        overrides: [
          meProvider.overrideWith(
            (_) =>
                replacement?.future ??
                Future.value(DemoSeed.me.copyWith(id: 'alice')),
          ),
          chatMediaApiProvider.overrideWithValue(_MediaApi(_MediaSession())),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: ChatMediaBubble(
                attachment: ChatMediaAttachment(
                  id: 'private-photo',
                  mediaType: 'photo',
                ),
                ownerId: 'alice',
                conversationType: 'direct',
                conversationId: 'thread',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNWidgets(2));
      replacement = Completer<UserProfile>();
      container.invalidate(meProvider);
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.text('Checking private media access…'), findsOneWidget);
      expect(
        find.text('Your account changed. Reopen this attachment.'),
        findsOneWidget,
      );
      replacement.complete(DemoSeed.me.copyWith(id: 'bob'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets(
    'commit disables cancellation including previously queued upload taps',
    (tester) async {
      final text = TextEditingController(text: 'Wait for confirmation');
      addTearDown(text.dispose);
      final session = _MediaSession()
        ..pending = Completer<ChatMediaAttachment>();
      final acknowledgement = Completer<void>();
      await _show(tester, session, text, (_, _) => acknowledgement.future);
      await _pick(tester);
      await tester.tap(find.byKey(const ValueKey('dm-send-message')));
      await tester.pump();
      await tester.pump();
      final cancelButton = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Cancel upload',
      );
      final queuedCancel = tester.widget<IconButton>(cancelButton).onPressed!;
      session.pending!.complete(
        const ChatMediaAttachment(id: 'ready-photo', mediaType: 'photo'),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.widget<IconButton>(cancelButton).onPressed, isNull);
      queuedCancel();
      await tester.pump();
      expect(session.canceled, isEmpty);
      expect(text.text, 'Wait for confirmation');
      acknowledgement.complete();
      await tester.pumpAndSettle();
      expect(text.text, isEmpty);
      expect(session.canceled, isEmpty);
    },
  );

  testWidgets('account change clears private file and caption drafts', (
    tester,
  ) async {
    final text = TextEditingController(text: 'Alice only');
    addTearDown(text.dispose);
    final session = _MediaSession();
    var owner = 'alice';
    await _show(
      tester,
      session,
      text,
      (_, _) async {},
      host: (_) => StatefulBuilder(
        builder: (context, update) => Column(
          children: [
            TextButton(
              onPressed: () => update(() => owner = 'bob'),
              child: const Text('Change account'),
            ),
            ChatMessageComposer(
              ownerId: owner,
              conversationType: 'direct',
              conversationId: 'thread',
              controller: text,
              onSend: (_, _) async {},
            ),
          ],
        ),
      ),
    );
    await _pick(tester);
    expect(find.text('chosen-photo.png'), findsOneWidget);
    await tester.tap(find.text('Change account'));
    await tester.pumpAndSettle();
    expect(text.text, isEmpty);
    expect(find.text('chosen-photo.png'), findsNothing);
  });

  testWidgets('chat video never autoplays and backgrounding pauses and mutes', (
    tester,
  ) async {
    final previous = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    addTearDown(() {
      VideoPlayerPlatform.instance = previous;
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatVideoViewer(
            url: 'https://private.example.invalid/video.mp4',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(platform.playing, isEmpty);
    expect(platform.volumes.values, everyElement(0));
    await tester.tap(find.byTooltip('Play video'));
    await tester.pumpAndSettle();
    expect(platform.playing, {0});
    await tester.tap(find.byTooltip('Toggle video sound'));
    await tester.pump();
    expect(platform.volumes[0], 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(platform.playing, isEmpty);
    expect(platform.volumes[0], 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(platform.playing, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
  testWidgets(
    'mutual consent prevents picking but leaves text messaging available',
    (tester) async {
      final text = TextEditingController(text: 'Hello');
      addTearDown(text.dispose);
      final session = _MediaSession();
      var picks = 0;
      var sent = '';
      await _show(
        tester,
        session,
        text,
        (value, id) async {
          sent = value;
        },
        allowed: false,
        onPick: () => picks++,
      );
      await _pick(tester);
      expect(picks, 0);
      expect(session.capabilityReads, 0);
      expect(find.textContaining('Both people must accept'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dm-send-message')));
      await tester.pumpAndSettle();
      expect(sent, 'Hello');
      expect(text.text, isEmpty);
    },
  );

  testWidgets('disabled provider explains availability without opening files', (
    tester,
  ) async {
    final text = TextEditingController();
    addTearDown(text.dispose);
    final session = _MediaSession()
      ..caps = const ChatMediaCapabilities(
        enabled: false,
        reason: 'Private media is coming soon.',
      );
    var picks = 0;
    await _show(tester, session, text, (_, _) async {}, onPick: () => picks++);
    await _pick(tester);
    expect(picks, 0);
    expect(find.textContaining('Private media is coming soon'), findsOneWidget);
  });

  testWidgets(
    'failed message retry keeps caption and ready attachment without reupload',
    (tester) async {
      final text = TextEditingController(text: 'Surf photo');
      addTearDown(text.dispose);
      final session = _MediaSession();
      final sends = <String?>[];
      await _show(tester, session, text, (_, attachment) async {
        sends.add(attachment);
        if (sends.length == 1) throw StateError('Connection lost');
      });
      await _pick(tester);
      expect(find.text('chosen-photo.png'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dm-send-message')));
      await tester.pumpAndSettle();
      expect(text.text, 'Surf photo');
      expect(find.text('chosen-photo.png'), findsOneWidget);
      expect(find.textContaining('Message not sent'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(sends, ['attachment-1', 'attachment-1']);
      expect(session.uploadCount, 1);
      expect(text.text, isEmpty);
      expect(find.text('chosen-photo.png'), findsNothing);
      expect(session.canceled, isEmpty);
    },
  );

  testWidgets(
    'cancel keeps local draft and ignores late reservation and upload result',
    (tester) async {
      final text = TextEditingController(text: 'Keep me');
      addTearDown(text.dispose);
      final session = _MediaSession()
        ..reservationGate = Completer<void>()
        ..pending = Completer<ChatMediaAttachment>();
      final sends = <String?>[];
      await _show(tester, session, text, (_, id) async => sends.add(id));
      await _pick(tester);
      await tester.tap(find.byKey(const ValueKey('dm-send-message')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('Cancel upload'));
      await tester.pumpAndSettle();
      expect(text.text, 'Keep me');
      expect(find.text('chosen-photo.png'), findsOneWidget);
      session.reservationGate!.complete();
      session.pending!.complete(
        const ChatMediaAttachment(id: 'late-private', mediaType: 'photo'),
      );
      await tester.pumpAndSettle();
      expect(session.canceled, ['reservation-1']);
      expect(sends, isEmpty);
      session.reservationGate = null;
      session.pending = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(sends, ['attachment-2']);
    },
  );

  testWidgets('removing a local attachment preserves its caption', (
    tester,
  ) async {
    final text = TextEditingController(text: 'Caption stays');
    addTearDown(text.dispose);
    final session = _MediaSession();
    await _show(tester, session, text, (_, _) async {});
    await _pick(tester);
    await tester.tap(find.byTooltip('Remove attachment'));
    await tester.pumpAndSettle();
    expect(text.text, 'Caption stays');
    expect(find.text('chosen-photo.png'), findsNothing);
    expect(session.uploadCount, 0);
  });

  testWidgets(
    'upload failure retains preview and sends no success until retried',
    (tester) async {
      final text = TextEditingController(text: 'Retry upload');
      addTearDown(text.dispose);
      final session = _MediaSession()..failUpload = true;
      var sends = 0;
      await _show(tester, session, text, (_, _) async {
        sends++;
      });
      await _pick(tester);
      await tester.tap(find.byKey(const ValueKey('dm-send-message')));
      await tester.pumpAndSettle();
      expect(sends, 0);
      expect(text.text, 'Retry upload');
      expect(find.text('chosen-photo.png'), findsOneWidget);
      session.failUpload = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(sends, 1);
    },
  );
}
