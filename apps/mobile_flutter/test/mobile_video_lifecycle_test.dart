import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  final calls = <String>[];
  bool initializeImmediately = true;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = streams.length;
    final stream = StreamController<VideoEvent>();
    streams[id] = stream;
    calls.add('create:$id');
    if (initializeImmediately) {
      stream.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: const Size(280, 350),
          duration: const Duration(seconds: 18),
        ),
      );
    }
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose:$playerId');
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause:$playerId');
  }

  @override
  Future<void> play(int playerId) async {
    calls.add('play:$playerId');
  }

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {
    calls.add('volume:$playerId:$volume');
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.black);
}

Widget _host({
  bool enabled = true,
  String url = 'https://video.example.invalid/clip.mp4',
}) => ProviderScope(
  child: MaterialApp(
    home: Scaffold(
      body: TickerMode(
        enabled: enabled,
        child: Center(
          child: SizedBox(
            width: 280,
            height: 350,
            child: AutoplayVideoPlayer(url: url, expand: true),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  late VideoPlayerPlatform original;
  late _VideoPlatform platform;
  setUp(() {
    original = VideoPlayerPlatform.instance;
    platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() async {
    VideoPlayerPlatform.instance = original;
    for (final stream in platform.streams.values) {
      await stream.close();
    }
  });

  testWidgets('hidden tab does not initialize a video', (tester) async {
    await tester.pumpWidget(_host(enabled: false));
    await tester.pump(const Duration(milliseconds: 50));
    expect(platform.calls.where((call) => call.startsWith('create:')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('loaded poster removes the covered repeating loader', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 280,
              height: 350,
              child: AutoplayVideoPlayer(
                active: false,
                url: 'https://video.example.invalid/clip.mp4',
                thumbnailUrl: 'https://image.example.invalid/poster.jpg',
                expand: true,
              ),
            ),
          ),
        ),
      ),
    );
    final poster = find.byWidgetPredicate(
      (widget) => widget is Image && widget.image is NetworkImage,
    );
    final image = tester.widget<Image>(poster);
    const loaded = ColoredBox(color: Colors.blue);
    expect(image.frameBuilder, isNotNull);
    expect(
      image.frameBuilder!(tester.element(poster), loaded, 0, false),
      same(loaded),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'video pauses on hidden tab and app background, resumes only visible',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(platform.calls, contains('play:0'));
      platform.calls.clear();
      await tester.pumpWidget(_host(enabled: false));
      await tester.pump();
      expect(platform.calls, contains('pause:0'));
      expect(platform.calls, isNot(contains('play:0')));
      await tester.pumpWidget(_host());
      await tester.pump();
      expect(platform.calls, contains('play:0'));
      platform.calls.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(platform.calls, contains('pause:0'));
      expect(platform.calls, isNot(contains('play:0')));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('lazy disposal during initialization ignores late video events', (
    tester,
  ) async {
    platform.initializeImmediately = false;
    await tester.pumpWidget(_host());
    await tester.pump();
    expect(platform.streams.length, 1);
    await tester.pumpWidget(const SizedBox());
    platform.streams[0]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: const Size(280, 350),
        duration: const Duration(seconds: 18),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(platform.calls, isNot(contains('play:0')));
  });
}
