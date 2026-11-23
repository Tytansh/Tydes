import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/post_media_viewer.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

Future<void> _show(
  WidgetTester tester, {
  int initialIndex = 0,
  int itemCount = 3,
  Widget Function(BuildContext, int, bool)? itemBuilder,
  ValueChanged<int>? onPageChanged,
}) async {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showPostMediaViewer(
                context,
                initialIndex: initialIndex,
                itemCount: itemCount,
                onPageChanged: onPageChanged,
                itemBuilder:
                    itemBuilder ??
                    (context, index, active) => ColoredBox(
                      color: Colors.blue,
                      child: Center(child: Text('Media $index $active')),
                    ),
              ),
              child: const Text('Open media'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open media'));
  await tester.pumpAndSettle();
}

class _Players extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  final playing = <int>{};
  final volumes = <int, double>{};
  final disposed = <int>{};

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = streams.length;
    streams[id] = StreamController<VideoEvent>()
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 18),
          size: const Size(400, 200),
        ),
      );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId]!.stream;
  @override
  Future<void> play(int playerId) async => playing.add(playerId);
  @override
  Future<void> pause(int playerId) async => playing.remove(playerId);
  @override
  Future<void> setVolume(int playerId, double volume) async {
    volumes[playerId] = volume;
  }

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
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
  Widget buildView(int playerId) => const ColoredBox(color: Colors.blue);
}

Future<void> _flush(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets('viewer is opaque, full-width and has a safe 44px close target', (
    tester,
  ) async {
    await _show(tester);
    final page = find.byKey(const ValueKey('post-media-viewer-pages'));
    expect(tester.getSize(page).width, 430);
    final route = ModalRoute.of(tester.element(page));
    expect(route, isA<MaterialPageRoute<void>>());
    expect((route! as MaterialPageRoute<void>).opaque, isTrue);
    expect(route.settings.name, 'post-media-viewer');
    final close = tester.getSize(find.byTooltip('Close media'));
    expect(close.width, greaterThanOrEqualTo(44));
    expect(close.height, greaterThanOrEqualTo(44));
    expect(find.text('1 of 3'), findsOneWidget);
    await tester.tap(find.byTooltip('Close media'));
    await tester.pumpAndSettle();
    expect(find.text('Open media'), findsOneWidget);
    expect(find.byTooltip('Close media'), findsNothing);
  });

  testWidgets(
    'arrows and keyboard select only one active item and stop at ends',
    (tester) async {
      final changes = <int>[];
      final latest = <int, bool>{};
      await _show(
        tester,
        initialIndex: 1,
        onPageChanged: changes.add,
        itemBuilder: (_, index, active) {
          latest[index] = active;
          return Center(child: Text('Item $index'));
        },
      );
      expect(latest[1], isTrue);
      expect(latest.entries.where((entry) => entry.value).length, 1);
      await tester.tap(find.byTooltip('Next media'));
      await tester.pumpAndSettle();
      expect(find.text('3 of 3'), findsOneWidget);
      expect(find.byTooltip('Next media'), findsNothing);
      expect(latest[1], isFalse);
      expect(latest[2], isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(changes, [2]);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('2 of 3'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Open media'), findsOneWidget);
    },
  );

  testWidgets(
    'pinch state suspends page gestures without rebuilding the route',
    (tester) async {
      late BuildContext mediaContext;
      await _show(
        tester,
        itemBuilder: (context, index, active) {
          if (active) mediaContext = context;
          return const ColoredBox(color: Colors.blue);
        },
      );
      final page = find.byKey(const ValueKey('post-media-viewer-pages'));
      final element = tester.element(page);
      notifyPostMediaViewerZoom(mediaContext, true);
      await tester.pump();
      expect(tester.element(page), same(element));
      expect(
        tester.widget<PageView>(page).physics,
        isA<NeverScrollableScrollPhysics>(),
      );
      expect(find.byTooltip('Next media'), findsNothing);
      notifyPostMediaViewerZoom(mediaContext, false);
      await tester.pump();
      expect(tester.widget<PageView>(page).physics, isA<PageScrollPhysics>());
      expect(find.byTooltip('Next media'), findsOneWidget);
      await tester.tap(find.byTooltip('Close media'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'empty media does not open a route and starting index is bounded',
    (tester) async {
      await _show(tester, itemCount: 0);
      expect(find.byTooltip('Close media'), findsNothing);
      await _show(tester, itemCount: 2, initialIndex: 20);
      expect(find.text('2 of 2'), findsOneWidget);
      expect(find.byTooltip('Next media'), findsNothing);
      await tester.tap(find.byTooltip('Close media'));
      await tester.pumpAndSettle();
      await _show(tester, itemCount: 1, initialIndex: -20);
      expect(find.text('Media'), findsOneWidget);
      expect(find.byTooltip('Next media'), findsNothing);
      expect(find.byTooltip('Previous media'), findsNothing);
    },
  );

  testWidgets(
    'opening video viewer silences feed; closing disposes viewer player',
    (tester) async {
      final original = VideoPlayerPlatform.instance;
      final players = _Players();
      VideoPlayerPlatform.instance = players;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
        VideoPlayerPlatform.instance = original;
        for (final stream in players.streams.values) {
          await stream.close();
        }
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [videoSoundEnabledProvider.overrideWith((_) => true)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Column(
                  children: [
                    TextButton(
                      onPressed: () => showPostMediaViewer(
                        context,
                        initialIndex: 0,
                        itemCount: 1,
                        itemBuilder: (_, index, active) => AutoplayVideoPlayer(
                          key: const ValueKey('viewer-video'),
                          url: 'https://video.example.invalid/clip.mp4',
                          active: active,
                          expand: true,
                        ),
                      ),
                      child: const Text('Open viewer'),
                    ),
                    const Expanded(
                      child: Center(
                        child: SizedBox(
                          width: 280,
                          height: 200,
                          child: AutoplayVideoPlayer(
                            key: ValueKey('feed-video'),
                            url: 'https://video.example.invalid/clip.mp4',
                            expand: true,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await _flush(tester);
      expect(players.playing, {0});
      expect(players.volumes[0], 1);
      await tester.tap(find.text('Open viewer'));
      await _flush(tester);
      expect(players.playing, {1});
      expect(players.volumes[0], 0);
      await tester.tap(find.byTooltip('Close media'));
      await _flush(tester);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.byKey(const ValueKey('viewer-video')), findsNothing);
      expect(players.disposed, contains(1));
      expect(players.playing, {0});
      expect(tester.takeException(), isNull);
    },
  );
}
