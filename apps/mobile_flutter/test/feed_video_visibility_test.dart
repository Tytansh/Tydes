import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

const _videoKey = ValueKey('feed-video');
const _viewportKey = ValueKey('feed-scroll-viewport');

class _RecordingVideoPlatform extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  final calls = <String>[];
  final volumes = <int, double>{};
  final playing = <int>{};
  final volumesAtPlay = <double>[];
  final sources = <String>[];
  bool initializeImmediately = true;
  Completer<void>? pendingPlay;
  final pendingPlays = <int, Completer<void>>{};
  final pendingCreations = <int, Completer<void>>{};

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = streams.length;
    streams[id] = StreamController<VideoEvent>(
      onCancel: () {
        calls.add('cancel:$id');
      },
    );
    volumes[id] = 1;
    sources.add(options.dataSource.uri!);
    calls.add('create:$id');
    if (initializeImmediately) initialize(id);
    await pendingCreations[id]?.future;
    return id;
  }

  void initialize(int playerId) {
    streams[playerId]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: const Size(400, 200),
        duration: const Duration(seconds: 18),
      ),
    );
  }

  void denyAutoplay(int playerId, String message) {
    playing.remove(playerId);
    streams[playerId]!.addError(
      PlatformException(code: 'VideoError', message: message),
    );
  }

  void failSource(int playerId) {
    playing.remove(playerId);
    streams[playerId]!.addError(
      PlatformException(
        code: 'MEDIA_ERR_NETWORK',
        message: 'The media source could not be loaded.',
      ),
    );
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId]!.stream;

  @override
  Future<void> play(int playerId) async {
    calls.add('play:$playerId');
    volumesAtPlay.add(volumes[playerId]!);
    await (pendingPlays[playerId] ?? pendingPlay)?.future;
    playing.add(playerId);
    calls.add('played:$playerId');
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause:$playerId');
    playing.remove(playerId);
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    calls.add('volume:$playerId:$volume');
    volumes[playerId] = volume;
  }

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose:$playerId');
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

Widget _feedHost({
  required ScrollController scrollController,
  bool soundEnabled = false,
  double topSpacer = 120,
  GlobalKey<NavigatorState>? navigatorKey,
  String url = 'https://video.example.invalid/clip.mp4',
  String? fallbackUrl,
}) => ProviderScope(
  overrides: [videoSoundEnabledProvider.overrideWith((ref) => soundEnabled)],
  child: MaterialApp(
    navigatorKey: navigatorKey,
    home: Scaffold(
      appBar: AppBar(toolbarHeight: 120, title: const Text('Feed')),
      bottomNavigationBar: NavigationBar(
        height: 120,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Feed'),
          NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
      body: SingleChildScrollView(
        key: _viewportKey,
        controller: scrollController,
        child: Column(
          children: [
            SizedBox(height: topSpacer),
            SizedBox(
              height: 200,
              // Feed media is inside a horizontal carousel. The outer vertical
              // position must still control playback and clipping visibility.
              child: PageView(
                children: [
                  AutoplayVideoPlayer(
                    key: _videoKey,
                    url: url,
                    fallbackUrl: fallbackUrl,
                    expand: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 1000),
          ],
        ),
      ),
    ),
  ),
);

Future<void> _flushPlayback(WidgetTester tester) async {
  // Do not pumpAndSettle: a playing controller polls its position repeatedly.
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _flushDisposals(WidgetTester tester) async {
  // Stream cancellation reaches the SDK's dispose continuation outside the
  // widget test's fake clock. Give that continuation one real event-loop turn.
  await tester.runAsync(() async {
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pump();
}

Future<void> _mountFeed(
  WidgetTester tester,
  _RecordingVideoPlatform platform, {
  required ScrollController scrollController,
  bool soundEnabled = false,
  double topSpacer = 120,
  GlobalKey<NavigatorState>? navigatorKey,
  String url = 'https://video.example.invalid/clip.mp4',
  String? fallbackUrl,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    final pendingPlay = platform.pendingPlay;
    if (pendingPlay != null && !pendingPlay.isCompleted) pendingPlay.complete();
    for (final pending in [
      ...platform.pendingPlays.values,
      ...platform.pendingCreations.values,
    ]) {
      if (!pending.isCompleted) pending.complete();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    scrollController.dispose();
  });
  await tester.pumpWidget(
    _feedHost(
      scrollController: scrollController,
      soundEnabled: soundEnabled,
      topSpacer: topSpacer,
      navigatorKey: navigatorKey,
      url: url,
      fallbackUrl: fallbackUrl,
    ),
  );
  await _flushPlayback(tester);
}

Future<void> _enableSound(
  WidgetTester tester,
  _RecordingVideoPlatform platform,
) async {
  await tester.tap(find.byIcon(Icons.volume_off_rounded));
  await _flushPlayback(tester);
  expect(platform.volumes[0], 1);
  expect(platform.playing, contains(0));
}

void main() {
  const hls =
      'https://video.example.invalid/clip/playlist.m3u8?token=A%2FB&expires=123';
  const fallback =
      'https://video.example.invalid/clip/play_720p.mp4?token=C%2FD&expires=456';
  late VideoPlayerPlatform original;
  late _RecordingVideoPlatform platform;

  setUp(() {
    original = VideoPlayerPlatform.instance;
    platform = _RecordingVideoPlatform();
    VideoPlayerPlatform.instance = platform;
  });

  tearDown(() async {
    VideoPlayerPlatform.instance = original;
    for (final stream in platform.streams.values) {
      await stream.close();
    }
  });

  testWidgets('HLS initialization failure tries the supplied MP4 once', (
    tester,
  ) async {
    platform.initializeImmediately = false;
    await _mountFeed(
      tester,
      platform,
      scrollController: ScrollController(),
      url: hls,
      fallbackUrl: fallback,
    );
    platform.failSource(0);
    await _flushPlayback(tester);
    platform.initialize(1);
    await _flushPlayback(tester);
    await _flushDisposals(tester);

    expect(platform.sources, [hls, fallback]);
    expect(platform.calls, contains('dispose:0'));
    expect(platform.playing, {1});
    expect(platform.volumesAtPlay, everyElement(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('runtime media failure falls back but never cycles to HLS', (
    tester,
  ) async {
    final scrollController = ScrollController();
    await _mountFeed(
      tester,
      platform,
      scrollController: scrollController,
      url: hls,
      fallbackUrl: fallback,
    );
    platform.failSource(0);
    await _flushPlayback(tester);
    expect(platform.sources, [hls, fallback]);
    expect(platform.playing, {1});

    platform.failSource(1);
    await _flushPlayback(tester);
    scrollController.jumpTo(520);
    await _flushPlayback(tester);
    scrollController.jumpTo(0);
    await _flushPlayback(tester);
    expect(platform.sources, [hls, fallback]);
    expect(platform.playing, isEmpty);
    expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);

    await tester.tap(find.byKey(_videoKey));
    await _flushPlayback(tester);
    expect(platform.sources, [hls, fallback, fallback]);
    expect(platform.playing, {2});
  });

  testWidgets('autoplay denial retries HLS muted without downloading MP4', (
    tester,
  ) async {
    await _mountFeed(
      tester,
      platform,
      scrollController: ScrollController(),
      soundEnabled: true,
      url: hls,
      fallbackUrl: fallback,
    );
    const denial = 'NotAllowedError: autoplay requires a user gesture';
    platform.denyAutoplay(0, denial);
    await _flushPlayback(tester);
    expect(platform.sources, [hls, hls]);
    expect(platform.volumes[1], 0);
    platform.denyAutoplay(1, denial);
    await _flushPlayback(tester);
    expect(platform.sources, [hls, hls]);
    expect(platform.playing, isEmpty);
  });

  testWidgets(
    'offscreen initialization failure defers fallback until visible',
    (tester) async {
      platform.initializeImmediately = false;
      final scrollController = ScrollController();
      await _mountFeed(
        tester,
        platform,
        scrollController: scrollController,
        url: hls,
        fallbackUrl: fallback,
      );
      scrollController.jumpTo(1000);
      await _flushPlayback(tester);
      platform.failSource(0);
      await _flushPlayback(tester);
      expect(platform.sources, [hls]);
      expect(platform.playing, isEmpty);

      scrollController.jumpTo(0);
      await _flushPlayback(tester);
      platform.initialize(1);
      await _flushPlayback(tester);
      expect(platform.sources, [hls, fallback]);
      expect(platform.playing, {1});
      expect(platform.volumesAtPlay, everyElement(0));
    },
  );

  testWidgets('fallback video retains offscreen and hidden-route silence', (
    tester,
  ) async {
    final scrollController = ScrollController();
    final navigatorKey = GlobalKey<NavigatorState>();
    await _mountFeed(
      tester,
      platform,
      scrollController: scrollController,
      navigatorKey: navigatorKey,
      soundEnabled: true,
      url: hls,
      fallbackUrl: fallback,
    );
    platform.failSource(0);
    await _flushPlayback(tester);
    expect(platform.playing, {1});
    expect(platform.volumes[1], 1);
    scrollController.jumpTo(520);
    await _flushPlayback(tester);
    expect(platform.playing, isEmpty);
    expect(platform.volumes[1], 0);
    scrollController.jumpTo(0);
    await _flushPlayback(tester);
    expect(platform.playing, {1});

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _flushPlayback(tester);
    expect(platform.playing, isEmpty);
    expect(platform.volumes[1], 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flushPlayback(tester);
    expect(platform.playing, {1});

    unawaited(
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (context) => const Scaffold(body: Text('Another route')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _flushPlayback(tester);
    expect(platform.playing, isEmpty);
    expect(platform.volumes[1], 0);
  });

  testWidgets('changing an attachment resets its bounded fallback state', (
    tester,
  ) async {
    final scrollController = ScrollController();
    await _mountFeed(
      tester,
      platform,
      scrollController: scrollController,
      url: hls,
      fallbackUrl: fallback,
    );
    platform.failSource(0);
    await _flushPlayback(tester);
    await tester.pumpWidget(
      _feedHost(
        scrollController: scrollController,
        url: hls,
        fallbackUrl: '$fallback&updated=1',
      ),
    );
    await _flushPlayback(tester);
    expect(platform.sources, [hls, fallback, hls]);
    platform.failSource(2);
    await _flushPlayback(tester);
    expect(platform.sources, [hls, fallback, hls, '$fallback&updated=1']);
    expect(platform.playing, {3});
  });

  testWidgets(
    'stale HLS play failure cannot fail over a replacement attachment',
    (tester) async {
      final stalePlay = Completer<void>();
      platform.pendingPlays[0] = stalePlay;
      final scrollController = ScrollController();
      await _mountFeed(
        tester,
        platform,
        scrollController: scrollController,
        url: hls,
        fallbackUrl: fallback,
      );
      final replacement = '$hls&replacement=1';
      await tester.pumpWidget(
        _feedHost(
          scrollController: scrollController,
          url: replacement,
          fallbackUrl: '$fallback&replacement=1',
        ),
      );
      await _flushPlayback(tester);
      stalePlay.completeError(
        PlatformException(
          code: 'NotSupportedError',
          message: 'Media unsupported',
        ),
      );
      await _flushPlayback(tester);
      await _flushDisposals(tester);
      expect(platform.sources, [hls, replacement]);
      expect(platform.playing, {1});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'visible feed autoplays muted even with sound preference enabled',
    (tester) async {
      await _mountFeed(
        tester,
        platform,
        scrollController: ScrollController(),
        soundEnabled: true,
      );

      expect(platform.calls, contains('play:0'));
      expect(
        platform.volumesAtPlay.first,
        0,
        reason:
            'A new video element must start muted to permit browser autoplay.',
      );
    },
  );

  testWidgets('pixels clipped by the top app bar do not count as visible', (
    tester,
  ) async {
    await _mountFeed(
      tester,
      platform,
      scrollController: ScrollController(initialScrollOffset: 240),
    );

    final video = tester.getRect(find.byKey(_videoKey));
    final viewport = tester.getRect(find.byKey(_viewportKey));
    expect(video.top, 0);
    expect(video.intersect(viewport).height, 80);
    expect(platform.calls, isNot(contains('play:0')));
    expect(platform.playing, isEmpty);
    expect(platform.volumes[0], 0);
  });

  testWidgets('pixels clipped by bottom navigation do not count as visible', (
    tester,
  ) async {
    await _mountFeed(
      tester,
      platform,
      scrollController: ScrollController(),
      topSpacer: 480,
    );

    final video = tester.getRect(find.byKey(_videoKey));
    final viewport = tester.getRect(find.byKey(_viewportKey));
    expect(video.bottom, 800);
    expect(video.intersect(viewport).height, 80);
    expect(platform.calls, isNot(contains('play:0')));
    expect(platform.playing, isEmpty);
    expect(platform.volumes[0], 0);
  });

  testWidgets('a video just below the feed viewport preloads without playing', (
    tester,
  ) async {
    await _mountFeed(
      tester,
      platform,
      scrollController: ScrollController(),
      topSpacer: 580,
    );

    final video = tester.getRect(find.byKey(_videoKey));
    final viewport = tester.getRect(find.byKey(_viewportKey));
    expect(video.top, greaterThan(viewport.bottom));
    expect(video.top, lessThan(viewport.bottom + viewport.height * 0.35));
    expect(platform.calls, contains('create:0'));
    expect(platform.calls, isNot(contains('play:0')));
    expect(platform.playing, isEmpty);
    expect(platform.volumes[0], 0);
  });

  testWidgets('outer feed scroll mutes and pauses an audible carousel video', (
    tester,
  ) async {
    final scrollController = ScrollController();
    await _mountFeed(tester, platform, scrollController: scrollController);
    await _enableSound(tester, platform);
    platform.calls.clear();

    scrollController.jumpTo(520);
    await _flushPlayback(tester);

    final video = tester.getRect(find.byKey(_videoKey));
    final viewport = tester.getRect(find.byKey(_viewportKey));
    expect(video.bottom, lessThanOrEqualTo(viewport.top));
    expect(find.byKey(_videoKey), findsOneWidget);
    expect(platform.calls, contains('volume:0:0.0'));
    expect(platform.calls, contains('pause:0'));
    expect(platform.calls, isNot(contains('play:0')));
    expect(platform.volumes[0], 0);
    expect(platform.playing, isEmpty);

    platform.calls.clear();
    scrollController.jumpTo(0);
    await _flushPlayback(tester);
    expect(platform.calls, contains('play:0'));
    expect(platform.playing, contains(0));
  });

  testWidgets('covered route mutes and pauses a mounted audible feed video', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await _mountFeed(
      tester,
      platform,
      scrollController: ScrollController(),
      navigatorKey: navigatorKey,
    );
    await _enableSound(tester, platform);
    platform.calls.clear();

    unawaited(
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (context) => const Scaffold(body: Text('Another route')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _flushPlayback(tester);

    expect(find.byKey(_videoKey, skipOffstage: false), findsOneWidget);
    expect(platform.calls, contains('volume:0:0.0'));
    expect(platform.calls, contains('pause:0'));
    expect(platform.calls, isNot(contains('play:0')));
    expect(platform.volumes[0], 0);
    expect(platform.playing, isEmpty);
  });

  testWidgets('initialization finishing offscreen does not start playback', (
    tester,
  ) async {
    platform.initializeImmediately = false;
    final scrollController = ScrollController();
    await _mountFeed(tester, platform, scrollController: scrollController);
    expect(platform.calls, contains('create:0'));

    scrollController.jumpTo(520);
    await _flushPlayback(tester);
    platform.initialize(0);
    await _flushPlayback(tester);

    expect(platform.calls, isNot(contains('play:0')));
    expect(platform.volumes[0], 0);
    expect(platform.playing, isEmpty);
  });

  testWidgets(
    'a late play completion cannot leave an offscreen video playing',
    (tester) async {
      platform.pendingPlay = Completer<void>();
      final scrollController = ScrollController();
      await _mountFeed(tester, platform, scrollController: scrollController);
      expect(platform.calls, contains('play:0'));

      scrollController.jumpTo(520);
      await _flushPlayback(tester);
      platform.pendingPlay!.complete();
      await _flushPlayback(tester);

      expect(platform.volumes[0], 0);
      expect(platform.playing, isEmpty);
      expect(
        platform.calls.lastIndexOf('pause:0'),
        greaterThan(platform.calls.lastIndexOf('played:0')),
      );
    },
  );

  testWidgets('a stale manual play callback cannot start an offscreen video', (
    tester,
  ) async {
    final scrollController = ScrollController();
    await _mountFeed(tester, platform, scrollController: scrollController);
    final videoTap = tester
        .widgetList<GestureDetector>(
          find.descendant(
            of: find.byKey(_videoKey),
            matching: find.byType(GestureDetector),
          ),
        )
        .firstWhere((widget) => widget.onTap != null)
        .onTap!;
    videoTap();
    await _flushPlayback(tester);
    expect(platform.playing, isEmpty);

    scrollController.jumpTo(520);
    await _flushPlayback(tester);
    platform.calls.clear();
    // Models a tap delivered just after the feed moved, not a hit-test on a
    // video which the user can no longer see.
    videoTap();
    await _flushPlayback(tester);

    expect(platform.calls, isNot(contains('play:0')));
    expect(platform.volumes[0], 0);
    expect(platform.playing, isEmpty);
  });

  testWidgets('Chrome interaction denial retries a new muted player once', (
    tester,
  ) async {
    await _mountFeed(
      tester,
      platform,
      scrollController: ScrollController(),
      soundEnabled: true,
    );

    platform.denyAutoplay(
      0,
      "play() failed because the user didn't interact with the document first",
    );
    await _flushPlayback(tester);
    await _flushDisposals(tester);

    expect(platform.calls, contains('dispose:0'));
    expect(platform.streams.length, 2);
    expect(platform.calls, contains('play:1'));
    expect(platform.volumes[1], 0);
    expect(platform.playing, {1});
    expect(find.byIcon(Icons.videocam_off_outlined), findsNothing);
  });

  testWidgets('a second policy denial stops retries until an explicit tap', (
    tester,
  ) async {
    final scrollController = ScrollController();
    await _mountFeed(
      tester,
      platform,
      scrollController: scrollController,
      soundEnabled: true,
    );
    const denial = 'NotAllowedError: autoplay requires a user gesture';
    platform.denyAutoplay(0, denial);
    await _flushPlayback(tester);
    expect(platform.calls, contains('play:1'));
    expect(platform.volumes[1], 0);

    platform.denyAutoplay(1, denial);
    await _flushPlayback(tester);
    scrollController.jumpTo(520);
    await _flushPlayback(tester);
    scrollController.jumpTo(0);
    await _flushPlayback(tester);
    await _flushDisposals(tester);

    expect(platform.streams.length, 2);
    expect(platform.calls, containsAll(['dispose:0', 'dispose:1']));
    expect(platform.playing, isEmpty);
    expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);

    await tester.tap(find.byKey(_videoKey));
    await _flushPlayback(tester);
    expect(platform.streams.length, 3);
    expect(platform.calls, contains('play:2'));
    expect(platform.playing, {2});
    expect(find.byIcon(Icons.videocam_off_outlined), findsNothing);
  });

  testWidgets('a stale play failure cannot strand replacement playback', (
    tester,
  ) async {
    final stalePlay = Completer<void>();
    platform.pendingPlays[0] = stalePlay;
    final scrollController = ScrollController();
    await _mountFeed(tester, platform, scrollController: scrollController);
    expect(platform.calls, contains('play:0'));

    await tester.pumpWidget(
      _feedHost(
        scrollController: scrollController,
        url: 'https://video.example.invalid/replacement.mp4',
      ),
    );
    await _flushPlayback(tester);
    expect(platform.calls, contains('create:1'));
    stalePlay.completeError(StateError('The replaced player rejected play'));
    await _flushPlayback(tester);
    await _flushDisposals(tester);

    expect(platform.calls, contains('dispose:0'));
    expect(platform.calls, contains('play:1'));
    expect(platform.playing, {1});
    expect(tester.takeException(), isNull);
  });

  testWidgets('a delayed creation is disposed after the feed is unmounted', (
    tester,
  ) async {
    final creation = Completer<void>();
    platform.pendingCreations[0] = creation;
    await _mountFeed(tester, platform, scrollController: ScrollController());
    expect(platform.calls, contains('create:0'));
    await tester.pumpWidget(const SizedBox.shrink());

    creation.complete();
    await _flushPlayback(tester);
    await _flushDisposals(tester);

    expect(platform.calls, contains('dispose:0'));
    expect(platform.calls, isNot(contains('play:0')));
    expect(platform.playing, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a delayed old creation cannot leak after the video URL changes',
    (tester) async {
      final oldCreation = Completer<void>();
      platform.pendingCreations[0] = oldCreation;
      final scrollController = ScrollController();
      await _mountFeed(tester, platform, scrollController: scrollController);
      expect(platform.calls, contains('create:0'));

      await tester.pumpWidget(
        _feedHost(
          scrollController: scrollController,
          url: 'https://video.example.invalid/replacement.mp4',
        ),
      );
      await _flushPlayback(tester);
      oldCreation.complete();
      await _flushPlayback(tester);
      await _flushDisposals(tester);

      expect(platform.calls, contains('dispose:0'));
      expect(platform.calls, isNot(contains('play:0')));
      expect(platform.calls, contains('play:1'));
      expect(platform.playing, {1});
      expect(tester.takeException(), isNull);
    },
  );
}
