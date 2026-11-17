import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _Images extends Fake implements HttpClient {
  _Images(this.bytes);
  final Uint8List bytes;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _ImageRequest(bytes);
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
  int get statusCode => 200;
  @override
  int get contentLength => bytes.length;
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

class _Videos extends VideoPlayerPlatform {
  Size sourceSize = const Size(80, 45);
  final streams = <int, StreamController<VideoEvent>>{};
  final playing = <int>{};
  final volumes = <int, double>{};
  final disposed = <int>[];
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = streams.length;
    streams[id] = StreamController<VideoEvent>()
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: sourceSize,
          duration: const Duration(seconds: 18),
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
    await streams[playerId]?.close();
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

void _mediaTest(
  String name,
  Future<void> Function(WidgetTester tester, _Videos videos) run,
) {
  testWidgets(name, (tester) async {
    final previousImages = debugNetworkImageHttpClientProvider;
    final previousVideos = VideoPlayerPlatform.instance;
    final videos = _Videos();
    VideoPlayerPlatform.instance = videos;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      await run(tester, videos);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      debugNetworkImageHttpClientProvider = previousImages;
      VideoPlayerPlatform.instance = previousVideos;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    }
  });
}

void _imageBytes(Size size) {
  final bytes = Uint8List.fromList(
    raster.encodePng(
      raster.fill(
        raster.Image(width: size.width.toInt(), height: size.height.toInt()),
        color: raster.ColorRgb8(220, 80, 40),
      ),
    ),
  );
  debugNetworkImageHttpClientProvider = () => _Images(bytes);
}

SocialMediaAttachmentModel _attachment(
  String type,
) => SocialMediaAttachmentModel.fromJson({
  'id': 'whole-frame-$type',
  'media_type': type,
  'url':
      'https://media.example.invalid/source.${type == 'video' ? 'mp4' : 'png'}',
  'thumbnail_url': type == 'video'
      ? 'https://media.example.invalid/poster.png'
      : '',
});

Future<void> _show(
  WidgetTester tester, {
  required double width,
  required String type,
  bool inactive = false,
}) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [videoSoundEnabledProvider.overrideWith((_) => false)],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TydesDesktopPostWidth(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: TickerMode(
                  enabled: !inactive,
                  child: SocialPostMediaCarousel(media: [_attachment(type)]),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _imageReady(WidgetTester tester) async {
  await tester.runAsync(
    () async => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pumpAndSettle();
}

void _expectBlackAncestor(Finder media) {
  expect(
    find.ancestor(
      of: media,
      matching: find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.color == Colors.black,
      ),
    ),
    findsWidgets,
    reason: 'Unused portrait-stage space must be black, not stretched media.',
  );
}

void _expectUncropped(Size source, Size stage) {
  final fit = applyBoxFit(BoxFit.contain, source, stage);
  expect(fit.source, source);
  expect(fit.destination.width, lessThanOrEqualTo(stage.width));
  expect(fit.destination.height, lessThanOrEqualTo(stage.height));
  expect(fit.destination.aspectRatio, closeTo(source.aspectRatio, .00001));
  if ((source.aspectRatio - stage.aspectRatio).abs() > .00001) {
    expect(fit.destination, isNot(stage));
  }
}

void _expectImageFit(WidgetTester tester, Size source) {
  final image = find.byWidgetPredicate(
    (widget) => widget is Image && widget.image is NetworkImage,
  );
  expect(image, findsOneWidget);
  final widget = tester.widget<Image>(image);
  expect(widget.fit, BoxFit.contain);
  expect(widget.alignment, Alignment.center);
  final decoded = tester
      .renderObject<RenderImage>(
        find.descendant(of: image, matching: find.byType(RawImage)),
      )
      .image;
  expect(decoded, isNotNull);
  expect(Size(decoded!.width.toDouble(), decoded.height.toDouble()), source);
  final stage = tester.getSize(find.byType(PageView));
  expect(stage.aspectRatio, closeTo(9 / 16, .00001));
  expect(stage.height, lessThanOrEqualTo(636));
  expect(tester.getSize(image), stage);
  _expectUncropped(source, stage);
  _expectBlackAncestor(image);
}

void main() {
  for (final shape in [
    ('landscape', const Size(80, 45)),
    ('portrait', const Size(45, 80)),
    ('square', const Size(40, 40)),
    ('extra-tall', const Size(45, 105)),
  ]) {
    for (final width in [390.0, 1400.0]) {
      _mediaTest('${shape.$1} feed photo stays whole at $width', (
        tester,
        videos,
      ) async {
        _imageBytes(shape.$2);
        await _show(tester, width: width, type: 'photo');
        await _imageReady(tester);
        _expectImageFit(tester, shape.$2);
        expect(videos.streams, isEmpty);
        expect(tester.takeException(), isNull);
      });

      _mediaTest('${shape.$1} feed video stays whole and muted at $width', (
        tester,
        videos,
      ) async {
        _imageBytes(shape.$2);
        videos.sourceSize = shape.$2;
        await _show(tester, width: width, type: 'video');
        for (var frame = 0; frame < 6; frame++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        final player = find.byType(VideoPlayer);
        expect(player, findsOneWidget);
        final fitted = find
            .ancestor(of: player, matching: find.byType(FittedBox))
            .first;
        expect(tester.widget<FittedBox>(fitted).fit, BoxFit.contain);
        final controller = tester.widget<VideoPlayer>(player).controller;
        expect(controller.value.size, shape.$2);
        final stage = tester.getSize(find.byType(PageView));
        expect(stage.aspectRatio, closeTo(9 / 16, .00001));
        expect(stage.height, lessThanOrEqualTo(636));
        _expectUncropped(shape.$2, stage);
        _expectBlackAncestor(player);
        expect(videos.streams, hasLength(1));
        expect(videos.playing, {0});
        expect(videos.volumes[0], 0);
        expect(tester.takeException(), isNull);
      });
    }

    _mediaTest('${shape.$1} inactive video poster stays whole on black', (
      tester,
      videos,
    ) async {
      _imageBytes(shape.$2);
      await _show(tester, width: 390, type: 'video', inactive: true);
      await _imageReady(tester);
      _expectImageFit(tester, shape.$2);
      expect(videos.streams, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
