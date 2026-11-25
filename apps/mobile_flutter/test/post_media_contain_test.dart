import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/widgets/phone_frosted_chrome.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _Images extends Fake implements HttpClient {
  _Images(this.bytes);
  static int requests = 0;
  static Completer<void>? responseGate;
  final Uint8List bytes;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests++;
    return _ImageRequest(bytes);
  }
}

class _ImageRequest extends Fake implements HttpClientRequest {
  _ImageRequest(this.bytes);
  final Uint8List bytes;
  @override
  Future<HttpClientResponse> close() async {
    await _Images.responseGate?.future;
    return _ImageResponse(bytes);
  }
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
  bool initializeImmediately = true;
  final streams = <int, StreamController<VideoEvent>>{};
  final playing = <int>{};
  final volumes = <int, double>{};
  final disposed = <int>[];
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = streams.length;
    streams[id] = StreamController<VideoEvent>();
    if (initializeImmediately) initialize(id);
    return id;
  }

  void initialize(int id) => streams[id]!.add(
    VideoEvent(
      eventType: VideoEventType.initialized,
      size: sourceSize,
      duration: const Duration(seconds: 18),
    ),
  );

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
    SocialPostMediaCarousel.clearCachedNaturalSizes();
    _Images.requests = 0;
    _Images.responseGate = null;
    VideoPlayerPlatform.instance = videos;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    try {
      await run(tester, videos);
    } finally {
      final gate = _Images.responseGate;
      if (gate != null && !gate.isCompleted) gate.complete();
      _Images.responseGate = null;
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
  double height = 1200,
  List<SocialMediaAttachmentModel>? media,
  EdgeInsets? chromeInsets,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final feed = SingleChildScrollView(
    child: TydesDesktopPostWidth(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22),
        child: TickerMode(
          enabled: !inactive,
          child: SocialPostMediaCarousel(media: media ?? [_attachment(type)]),
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [videoSoundEnabledProvider.overrideWith((_) => false)],
      child: MaterialApp(
        home: Scaffold(
          body: chromeInsets == null
              ? feed
              : FeedChromeInsets(
                  insets: chromeInsets,
                  viewportHeight: height,
                  child: feed,
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
  if (tester.view.physicalSize.width < 600) {
    final ratio = source.aspectRatio;
    expect(
      stage.height,
      closeTo((stage.width / ratio).clamp(0.0, 900.0), .00001),
    );
  } else {
    expect(stage.width, 636);
    expect(
      stage.height,
      closeTo((stage.width / source.aspectRatio).clamp(0.0, 650.0), .00001),
    );
  }
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
        expect(
          _Images.requests,
          1,
          reason: 'Reading dimensions must reuse the photo fetch.',
        );
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
        if (width < 600) {
          expect(
            stage.height,
            closeTo(
              (stage.width / shape.$2.aspectRatio).clamp(0.0, 900.0),
              .00001,
            ),
          );
        } else {
          expect(stage.width, 636);
          expect(
            stage.height,
            closeTo(
              (stage.width / shape.$2.aspectRatio).clamp(0.0, 650.0),
              .00001,
            ),
          );
        }
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
      await _show(
        tester,
        width: 390,
        type: 'video',
        inactive: true,
        media: [
          SocialMediaAttachmentModel.fromJson({
            'id': 'sized-poster',
            'media_type': 'video',
            'url': 'https://media.example.invalid/sized-poster.mp4',
            'thumbnail_url': 'https://media.example.invalid/poster.png',
            'width': shape.$2.width.toInt(),
            'height': shape.$2.height.toInt(),
          }),
        ],
      );
      await _imageReady(tester);
      _expectImageFit(tester, shape.$2);
      expect(videos.streams, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  _mediaTest(
    'legacy video stays compact until it can appear at the correct size',
    (tester, videos) async {
      videos.initializeImmediately = false;
      _imageBytes(const Size(80, 45));
      await _show(tester, width: 390, height: 932, type: 'video');
      final originalState = tester.state(find.byType(AutoplayVideoPlayer));
      expect(tester.getSize(find.byType(PageView)), const Size(346, 120));
      expect(find.byType(VideoPlayer), findsNothing);
      expect(
        tester
            .widget<AutoplayVideoPlayer>(find.byType(AutoplayVideoPlayer))
            .awaitingNaturalSize,
        isTrue,
      );
      expect(videos.streams, hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.getSize(find.byType(PageView)), const Size(346, 120));
      videos.sourceSize = const Size(1920, 1080);
      videos.initialize(0);
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.getSize(find.byType(PageView)), const Size(346, 194.625));
      expect(
        tester.state(find.byType(AutoplayVideoPlayer)),
        same(originalState),
      );
      expect(videos.streams, hasLength(1));
      expect(videos.playing, {0});
      expect(
        tester
            .widget<AutoplayVideoPlayer>(find.byType(AutoplayVideoPlayer))
            .awaitingNaturalSize,
        isFalse,
      );
    },
  );

  _mediaTest('legacy photo first appears in its resolved natural frame', (
    tester,
    videos,
  ) async {
    _imageBytes(const Size(80, 45));
    final gate = _Images.responseGate = Completer<void>();
    await _show(tester, width: 390, height: 932, type: 'photo');
    expect(tester.getSize(find.byType(PageView)), const Size(346, 120));
    await tester.pump(const Duration(seconds: 2));
    expect(tester.getSize(find.byType(PageView)), const Size(346, 120));
    gate.complete();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final visibleImages = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .where((image) => image.image != null);
      if (visibleImages.isNotEmpty) {
        expect(tester.getSize(find.byType(PageView)), const Size(346, 194.625));
      }
    }
    _expectImageFit(tester, const Size(80, 45));
    expect(_Images.requests, 1);
    expect(videos.streams, isEmpty);
  });

  _mediaTest('remounted photo reserves its cached size during a slow reload', (
    tester,
    videos,
  ) async {
    _imageBytes(const Size(80, 45));
    await _show(tester, width: 390, height: 932, type: 'photo');
    await _imageReady(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    final gate = _Images.responseGate = Completer<void>();
    await _show(tester, width: 390, height: 932, type: 'photo');
    expect(tester.getSize(find.byType(PageView)), const Size(346, 194.625));
    gate.complete();
    await _imageReady(tester);
    _expectImageFit(tester, const Size(80, 45));
    expect(_Images.requests, 2);
  });

  _mediaTest(
    'uploaded photo dimensions reserve the final frame before decoding',
    (tester, videos) async {
      _imageBytes(const Size(80, 45));
      final gate = _Images.responseGate = Completer<void>();
      await _show(
        tester,
        width: 390,
        height: 932,
        type: 'photo',
        media: [
          SocialMediaAttachmentModel.fromJson({
            'id': 'photo-with-dimensions',
            'media_type': 'photo',
            'url': 'https://media.example.invalid/photo-with-dimensions.png',
            'thumbnail_url': '',
            'width': 80,
            'height': 45,
          }),
        ],
      );
      expect(tester.getSize(find.byType(PageView)), const Size(346, 194.625));
      gate.complete();
      await _imageReady(tester);
      _expectImageFit(tester, const Size(80, 45));
      expect(_Images.requests, 1);
    },
  );

  _mediaTest('remounted video reserves its known size before initializing', (
    tester,
    videos,
  ) async {
    _imageBytes(const Size(80, 45));
    await _show(tester, width: 390, height: 932, type: 'video');
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.getSize(find.byType(PageView)), const Size(346, 194.625));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    videos.initializeImmediately = false;
    await _show(tester, width: 390, height: 932, type: 'video');
    expect(tester.getSize(find.byType(PageView)), const Size(346, 194.625));
    expect(videos.streams, hasLength(2));
    videos.initialize(1);
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.getSize(find.byType(PageView)), const Size(346, 194.625));
  });

  _mediaTest('changed media URL does not reuse stale dimensions', (
    tester,
    videos,
  ) async {
    _imageBytes(const Size(80, 45));
    await _show(tester, width: 390, height: 932, type: 'video');
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    videos.initializeImmediately = false;
    await _show(
      tester,
      width: 390,
      height: 932,
      type: 'video',
      media: [
        SocialMediaAttachmentModel.fromJson({
          'id': 'whole-frame-video',
          'media_type': 'video',
          'url': 'https://media.example.invalid/replacement.mp4',
          'thumbnail_url': '',
        }),
      ],
    );
    expect(tester.getSize(find.byType(PageView)), const Size(346, 120));
    expect(find.byType(VideoPlayer), findsNothing);
  });

  _mediaTest('metadata gives natural phone proportions before image decoding', (
    tester,
    videos,
  ) async {
    videos.initializeImmediately = false;
    await _show(
      tester,
      width: 430,
      height: 932,
      type: 'video',
      media: [
        SocialMediaAttachmentModel.fromJson({
          'id': 'metadata-first',
          'media_type': 'video',
          'url': 'https://media.example.invalid/metadata.mp4',
          'thumbnail_url': '',
          'width': 1920,
          'height': 1080,
        }),
      ],
    );
    expect(tester.getSize(find.byType(PageView)), const Size(386, 217.125));
    videos.sourceSize = const Size(1920, 1080);
    videos.initialize(0);
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.getSize(find.byType(PageView)), const Size(386, 217.125));
  });

  _mediaTest('phone tall originals are bounded to the usable feed height', (
    tester,
    videos,
  ) async {
    videos.initializeImmediately = false;
    await _show(
      tester,
      width: 430,
      height: 800,
      type: 'video',
      media: [
        SocialMediaAttachmentModel.fromJson({
          'id': 'very-tall',
          'media_type': 'video',
          'url': 'https://media.example.invalid/tall.mp4',
          'thumbnail_url': '',
          'width': 400,
          'height': 2000,
        }),
      ],
    );
    final stage = tester.getSize(find.byType(PageView));
    expect(stage, const Size(386, 604));
    _expectUncropped(const Size(400, 2000), stage);
  });

  _mediaTest(
    'desktop legacy video waits for dimensions without replacing playback',
    (tester, videos) async {
      videos.initializeImmediately = false;
      _imageBytes(const Size(80, 45));
      await _show(tester, width: 1400, type: 'video');
      final originalState = tester.state(find.byType(AutoplayVideoPlayer));
      expect(tester.getSize(find.byType(PageView)), const Size(636, 120));
      expect(find.byType(VideoPlayer), findsNothing);
      expect(
        tester
            .widget<AutoplayVideoPlayer>(find.byType(AutoplayVideoPlayer))
            .awaitingNaturalSize,
        isTrue,
      );
      expect(videos.streams, hasLength(1));
      videos.sourceSize = const Size(1920, 1080);
      videos.initialize(0);
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.getSize(find.byType(PageView)), const Size(636, 357.75));
      expect(
        tester.state(find.byType(AutoplayVideoPlayer)),
        same(originalState),
      );
      expect(videos.streams, hasLength(1));
      expect(videos.playing, {0});
    },
  );

  _mediaTest('desktop photo only appears in its decoded natural frame', (
    tester,
    videos,
  ) async {
    _imageBytes(const Size(80, 45));
    final gate = _Images.responseGate = Completer<void>();
    await _show(tester, width: 1400, type: 'photo');
    expect(tester.getSize(find.byType(PageView)), const Size(636, 120));
    gate.complete();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final visibleImages = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .where((image) => image.image != null);
      if (visibleImages.isNotEmpty) {
        expect(tester.getSize(find.byType(PageView)), const Size(636, 357.75));
      }
    }
    _expectImageFit(tester, const Size(80, 45));
    expect(_Images.requests, 1);
    expect(videos.streams, isEmpty);
  });

  for (final dimensions in [const Size(1920, 1080), const Size(1080, 1920)]) {
    _mediaTest(
      'desktop reserves metadata $dimensions before video initialization',
      (tester, videos) async {
        videos.initializeImmediately = false;
        await _show(
          tester,
          width: 1400,
          type: 'video',
          media: [
            SocialMediaAttachmentModel.fromJson({
              'id': 'desktop-metadata',
              'media_type': 'video',
              'url': 'https://media.example.invalid/desktop-metadata.mp4',
              'thumbnail_url': '',
              'width': dimensions.width.toInt(),
              'height': dimensions.height.toInt(),
            }),
          ],
        );
        final expected = Size(
          636,
          (636 / dimensions.aspectRatio).clamp(0.0, 650.0),
        );
        expect(tester.getSize(find.byType(PageView)), expected);
        videos.sourceSize = dimensions;
        videos.initialize(0);
        for (var frame = 0; frame < 6; frame++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(tester.getSize(find.byType(PageView)), expected);
        _expectUncropped(dimensions, expected);
        expect(videos.streams, hasLength(1));
        expect(videos.playing, {0});
      },
    );
  }

  _mediaTest(
    'desktop remount keeps cached dimensions before playback is ready',
    (tester, videos) async {
      _imageBytes(const Size(80, 45));
      await _show(tester, width: 1400, type: 'video');
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.getSize(find.byType(PageView)), const Size(636, 357.75));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      videos.initializeImmediately = false;
      await _show(tester, width: 1400, type: 'video');
      expect(tester.getSize(find.byType(PageView)), const Size(636, 357.75));
      expect(videos.streams, hasLength(2));
      videos.initialize(1);
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.getSize(find.byType(PageView)), const Size(636, 357.75));
    },
  );

  _mediaTest('desktop carousel changes ratio and caps tall slides at 650px', (
    tester,
    videos,
  ) async {
    videos.initializeImmediately = false;
    final attachments = [
      for (final (id, width, height) in [
        ('desktop-wide', 1600, 900),
        ('desktop-tall', 900, 1600),
      ])
        SocialMediaAttachmentModel.fromJson({
          'id': id,
          'media_type': 'video',
          'url': 'https://media.example.invalid/$id.mp4',
          'thumbnail_url': '',
          'width': width,
          'height': height,
        }),
    ];
    await _show(tester, width: 1400, type: 'video', media: attachments);
    expect(tester.getSize(find.byType(PageView)), const Size(636, 357.75));
    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.getSize(find.byType(PageView)), const Size(636, 650));
    _expectUncropped(const Size(900, 1600), const Size(636, 650));
  });

  _mediaTest(
    'opening and closing phone video viewer silences the covered feed',
    (tester, videos) async {
      _imageBytes(const Size(80, 45));
      await _show(tester, width: 390, height: 932, type: 'video');
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(videos.playing, {0});
      await tester.tap(find.byType(VideoPlayer));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close media'), findsOneWidget);
      expect(videos.streams, hasLength(2));
      expect(videos.volumes[0], 0);
      expect(videos.playing, {1});
      await tester.tap(find.byTooltip('Close media'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.byTooltip('Close media'), findsNothing);
      expect(videos.playing, {0});
      expect(videos.disposed, contains(1));
      expect(videos.streams, hasLength(2));
    },
  );

  _mediaTest('selected phone slide adopts its own proportions after swiping', (
    tester,
    videos,
  ) async {
    videos.initializeImmediately = false;
    final attachments = [
      for (final (id, width, height) in [
        ('wide', 1600, 900),
        ('tall', 900, 1600),
      ])
        SocialMediaAttachmentModel.fromJson({
          'id': id,
          'media_type': 'video',
          'url': 'https://media.example.invalid/$id.mp4',
          'thumbnail_url': '',
          'width': width,
          'height': height,
        }),
    ];
    await _show(tester, width: 390, type: 'video', media: attachments);
    expect(
      tester.getSize(find.byType(PageView)).aspectRatio,
      closeTo(16 / 9, .00001),
    );
    await tester.drag(find.byType(PageView), const Offset(-330, 0));
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page,
      closeTo(1, .001),
    );
    expect(
      tester.getSize(find.byType(PageView)).aspectRatio,
      closeTo(9 / 16, .00001),
    );
  });

  _mediaTest('glass-covered video pixels preload but do not trigger autoplay', (
    tester,
    videos,
  ) async {
    _imageBytes(const Size(80, 45));
    await _show(
      tester,
      width: 390,
      height: 932,
      type: 'video',
      chromeInsets: const EdgeInsets.only(top: 300),
    );
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(videos.streams, hasLength(1));
    expect(videos.playing, isEmpty);
    expect(videos.volumes[0], 0);
  });
}
