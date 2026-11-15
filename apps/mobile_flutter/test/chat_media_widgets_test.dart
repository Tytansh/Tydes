import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as raster;
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
  int uploadCount = 0, capabilityReads = 0, accessReads = 0;
  bool videoAccess = false, videoThumbnail = false, failAccess = false;
  Completer<Map<String, dynamic>>? pendingAccess;
  final canceled = <String>[];
  Completer<ChatMediaAttachment>? pending;
  Completer<void>? reservationGate;
  bool failUpload = false;
  @override
  Future<Map<String, dynamic>> access(String id) async {
    accessReads++;
    if (failAccess) throw StateError('Private attachment access expired.');
    return pendingAccess?.future ??
        {
          'id': id,
          'media_type': videoAccess ? 'video' : 'photo',
          'url':
              'https://private.example.invalid/$id.${videoAccess ? 'mp4' : 'png'}',
          if (videoThumbnail)
            'thumbnail_url':
                'https://private.example.invalid/$id-thumbnail.png',
        };
  }

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
  _NamedPhoto([Uint8List? bytes])
    : super.fromData(
        bytes ??
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
  XFile? pickedFile,
}) async {
  final container = ProviderContainer(
    overrides: [
      chatMediaApiProvider.overrideWithValue(_MediaApi(session)),
      chatMediaPickerProvider.overrideWithValue(() async {
        onPick?.call();
        return pickedFile ?? _photo();
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

Uint8List _rasterPhoto(int width, int height) => Uint8List.fromList(
  raster.encodePng(
    raster.fill(
      raster.Image(width: width, height: height),
      color: raster.ColorRgb8(230, 70, 40),
    ),
  ),
);

class _ImageClient extends Fake implements HttpClient {
  _ImageClient(this.bytes);
  final Uint8List bytes;
  int reads = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    reads++;
    return _ImageRequest(bytes);
  }
}

class _ImageRequest extends Fake implements HttpClientRequest {
  _ImageRequest(this.bytes);
  final Uint8List bytes;
  @override
  Future<HttpClientResponse> close() async => _ImageResponse(bytes);
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  _ImageResponse(this.bytes);
  final Uint8List bytes;
  @override
  int get contentLength => bytes.length;
  @override
  int get statusCode => 200;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

_ImageClient _stubImages(Uint8List bytes) {
  final previous = debugNetworkImageHttpClientProvider;
  final client = _ImageClient(bytes);
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
  debugNetworkImageHttpClientProvider = () => client;
  addTearDown(() {
    debugNetworkImageHttpClientProvider = previous;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  return client;
}

void _mediaWidgetTest(
  String description,
  Future<void> Function(WidgetTester) run,
) {
  testWidgets(description, (tester) async {
    final previous = debugNetworkImageHttpClientProvider;
    try {
      await run(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugNetworkImageHttpClientProvider = previous;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.pump();
    }
  });
}

Future<void> _decodedImage(WidgetTester tester) async {
  // Codec completion runs outside the fake widget clock; no real I/O occurs.
  await tester.runAsync(
    () async => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pumpAndSettle();
  expect(
    tester.renderObject<RenderImage>(find.byType(RawImage).first).image,
    isNotNull,
  );
}

void _expectLetterbox(
  WidgetTester tester,
  Finder image,
  Size source,
  Size frame,
) {
  expect(tester.getSize(image), frame);
  expect(tester.widget<Image>(image).fit, BoxFit.contain);
  final fitted = applyBoxFit(BoxFit.contain, source, frame);
  expect(
    fitted.source,
    source,
    reason: 'The entire photo/video frame is visible.',
  );
  expect(fitted.destination.width, lessThanOrEqualTo(frame.width));
  expect(fitted.destination.height, lessThanOrEqualTo(frame.height));
  expect(
    fitted.destination.width / fitted.destination.height,
    closeTo(source.width / source.height, .00001),
  );
  final black = find.ancestor(
    of: image,
    matching: find.byWidgetPredicate(
      (widget) => widget is ColoredBox && widget.color == Colors.black,
    ),
  );
  expect(black, findsWidgets, reason: 'Unused sides or top/bottom are black.');
  if ((source.aspectRatio - frame.aspectRatio).abs() > .00001) {
    expect(
      fitted.destination == frame,
      isFalse,
      reason: 'Aspect mismatch is letterboxed, never cropped or stretched.',
    );
  }
}

Future<ProviderContainer> _showBubble(
  WidgetTester tester,
  _MediaSession session, {
  double width = 600,
  String type = 'photo',
  Widget Function(Widget)? host,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      meProvider.overrideWith((_) async => DemoSeed.me.copyWith(id: 'alice')),
      chatMediaApiProvider.overrideWithValue(_MediaApi(session)),
    ],
  );
  addTearDown(container.dispose);
  await container.read(meProvider.future);
  final bubble = Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: (width * .78 - 28).clamp(0, 280),
      child: ChatMediaBubble(
        key: const ValueKey('stable-attachment'),
        attachment: ChatMediaAttachment(id: 'private-layout', mediaType: type),
        ownerId: 'alice',
        conversationType: 'direct',
        conversationId: 'thread',
      ),
    ),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: host?.call(bubble) ?? bubble)),
    ),
  );
  if (session.pendingAccess == null) {
    await tester.pump();
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
  return container;
}

void main() {
  for (final shape in [
    (80, 40, 'landscape'),
    (40, 80, 'portrait'),
    (40, 40, 'square'),
  ]) {
    for (final width in [320.0, 600.0]) {
      _mediaWidgetTest(
        '${shape.$3} private photo letterboxes within current chat bounds at $width',
        (tester) async {
          _stubImages(_rasterPhoto(shape.$1, shape.$2));
          await _showBubble(tester, _MediaSession(), width: width);
          await _decodedImage(tester);
          final frame = Size((width * .78 - 28).clamp(0, 280), 190);
          expect(tester.getSize(find.byType(ChatMediaBubble)), frame);
          _expectLetterbox(
            tester,
            find.byType(Image),
            Size(shape.$1.toDouble(), shape.$2.toDouble()),
            frame,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
    _mediaWidgetTest(
      '${shape.$3} composer photo keeps whole image in the same64px preview',
      (tester) async {
        final text = TextEditingController();
        addTearDown(text.dispose);
        await _show(
          tester,
          _MediaSession(),
          text,
          (_, _) async {},
          pickedFile: _NamedPhoto(_rasterPhoto(shape.$1, shape.$2)),
        );
        await _pick(tester);
        await _decodedImage(tester);
        _expectLetterbox(
          tester,
          find.byType(Image),
          Size(shape.$1.toDouble(), shape.$2.toDouble()),
          const Size(64, 64),
        );
        expect(tester.takeException(), isNull);
      },
    );
    _mediaWidgetTest(
      '${shape.$3} private video thumbnail is contained, not cropped',
      (tester) async {
        _stubImages(_rasterPhoto(shape.$1, shape.$2));
        await _showBubble(
          tester,
          _MediaSession()
            ..videoAccess = true
            ..videoThumbnail = true,
          type: 'video',
        );
        await _decodedImage(tester);
        _expectLetterbox(
          tester,
          find.byType(Image),
          Size(shape.$1.toDouble(), shape.$2.toDouble()),
          const Size(280, 190),
        );
        expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  _mediaWidgetTest(
    'same-scope rebuild retains resolved signed image and access future',
    (tester) async {
      final client = _stubImages(_rasterPhoto(80, 40));
      final session = _MediaSession();
      var rebuilds = 0;
      await _showBubble(
        tester,
        session,
        host: (bubble) => StatefulBuilder(
          builder: (context, update) => Column(
            children: [
              TextButton(
                onPressed: () => update(() => rebuilds++),
                child: Text('Unrelated $rebuilds'),
              ),
              // Rebuild configuration, not identity, just as unchanged polls do.
              ChatMediaBubble(
                key: const ValueKey('stable-attachment'),
                attachment: const ChatMediaAttachment(
                  id: 'private-layout',
                  mediaType: 'photo',
                ),
                ownerId: 'alice',
                conversationType: 'direct',
                conversationId: 'thread',
              ),
            ],
          ),
        ),
      );
      await _decodedImage(tester);
      final state = tester.state(find.byType(ChatMediaBubble));
      final image = tester.element(find.byType(Image));
      final decoded = tester
          .renderObject<RenderImage>(find.byType(RawImage))
          .image;
      expect(session.accessReads, 1);
      expect(client.reads, 1);
      await tester.tap(find.text('Unrelated 0'));
      await tester.pumpAndSettle();
      expect(session.accessReads, 1);
      expect(client.reads, 1);
      expect(tester.state(find.byType(ChatMediaBubble)), same(state));
      expect(tester.element(find.byType(Image)), same(image));
      expect(
        tester.renderObject<RenderImage>(find.byType(RawImage)).image,
        same(decoded),
      );
    },
  );

  _mediaWidgetTest('private access loading retains the compact black frame', (
    tester,
  ) async {
    final session = _MediaSession()
      ..pendingAccess = Completer<Map<String, dynamic>>();
    await _showBubble(tester, session);
    expect(tester.getSize(find.byType(ChatMediaBubble)), const Size(280, 190));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ChatMediaBubble),
        matching: find.byWidgetPredicate(
          (widget) => widget is ColoredBox && widget.color == Colors.black,
        ),
      ),
      findsOneWidget,
    );
    session.pendingAccess!.complete({
      'id': 'private-layout',
      'media_type': 'photo',
      'url': 'https://private.example.invalid/layout.png',
    });
    await tester.pumpAndSettle();
  });

  _mediaWidgetTest(
    'immediately failed viewer renewal renders retry without an uncaught error',
    (tester) async {
      _stubImages(_rasterPhoto(80, 40));
      final session = _MediaSession();
      await _showBubble(tester, session);
      await _decodedImage(tester);
      expect(session.accessReads, 1);

      session.failAccess = true;
      await tester.tap(
        find.descendant(
          of: find.byType(ChatMediaBubble),
          matching: find.byType(InkWell),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Reload attachment'), findsOneWidget);
      expect(session.accessReads, 3);

      session.failAccess = false;
      await tester.tap(find.text('Reload attachment'));
      await tester.pump();
      await tester.pump();
      await _decodedImage(tester);
      expect(find.text('Reload attachment'), findsNothing);
      expect(session.accessReads, 4);
      expect(tester.takeException(), isNull);
    },
  );

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
