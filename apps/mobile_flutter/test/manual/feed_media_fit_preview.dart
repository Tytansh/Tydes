// Local layout QA only. Never publish this entrypoint.
// Example: flutter run -d chrome -t test/manual/feed_media_fit_preview.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  // The real carousel/player receives a local fake platform. No video URL is
  // downloaded, no accounts are loaded, and there are no upload/post controls.
  VideoPlayerPlatform.instance = _PreviewVideoPlatform();
  runApp(const ProviderScope(child: _FeedMediaPreview()));
}

class _FeedMediaPreview extends StatefulWidget {
  const _FeedMediaPreview();

  @override
  State<_FeedMediaPreview> createState() => _FeedMediaPreviewState();
}

class _FeedMediaPreviewState extends State<_FeedMediaPreview> {
  bool _dark = false;
  double _width = 680;

  String _local(String path) => Uri.base.resolve(path).toString();

  Widget _post(String title, List<SocialMediaAttachmentModel> media) =>
      TydesDesktopPostWidth(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                SocialPostMediaCarousel(media: media),
                const SizedBox(height: 12),
                const Text(
                  'Whole frame visible. Black letterboxing is intentional. '
                  'Use arrows/dots to compare the landscape and square slides.',
                ),
              ],
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
    home: Scaffold(
      appBar: AppBar(
        title: const Text('Feed media fit — local preview'),
        actions: [
          const Text('Dark'),
          Switch(
            value: _dark,
            onChanged: (value) => setState(() => _dark = value),
          ),
        ],
      ),
      body: Column(
        children: [
          const Material(
            color: Color(0xFFFFE6A2),
            child: SafeArea(
              top: false,
              bottom: false,
              child: Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    'LOCAL LAYOUT PREVIEW – no uploads/posts',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFF302600),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text('Preview width: ${_width.round()}px'),
                Expanded(
                  child: Slider(
                    value: _width,
                    min: 300,
                    max: 1000,
                    divisions: 70,
                    onChanged: (value) => setState(() => _width = value),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 36),
              child: Center(
                child: SizedBox(
                  width: _width,
                  child: Column(
                    children: [
                      _post('Photos: landscape ocean + square logo', [
                        SocialMediaAttachmentModel.fromJson({
                          'id': 'local-layout-landscape',
                          'media_type': 'photo',
                          'url': _local('/assets/assets/images/auth-surf-ocean.webp'),
                          'thumbnail_url': '',
                        }),
                        SocialMediaAttachmentModel.fromJson({
                          'id': 'local-layout-square',
                          'media_type': 'photo',
                          'url': _local('/icons/tydes-app-512.png'),
                          'thumbnail_url': '',
                        }),
                      ]),
                      const SizedBox(height: 24),
                      _post('Video: fake 1600 × 900 — no video download', [
                        SocialMediaAttachmentModel.fromJson({
                          'id': 'local-layout-video',
                          'media_type': 'video',
                          'url': _local('/layout-only-not-a-real-video.mp4'),
                          'thumbnail_url': '',
                        }),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _PreviewVideoPlatform extends VideoPlayerPlatform {
  final _events = <int, StreamController<VideoEvent>>{};
  int _nextId = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    _events[id] = StreamController<VideoEvent>()
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 18),
          size: const Size(1600, 900),
        ),
      );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Widget buildView(int playerId) => const ColoredBox(
    color: Color(0xFF156B80),
    child: Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: Text(
            'LOCAL VIDEO STAGE\n1600 × 900 — all four corners visible',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
        ),
        Positioned(top: 6, left: 6, child: _Corner('TOP LEFT')),
        Positioned(top: 6, right: 6, child: _Corner('TOP RIGHT')),
        Positioned(bottom: 6, left: 6, child: _Corner('BOTTOM LEFT')),
        Positioned(bottom: 6, right: 6, child: _Corner('BOTTOM RIGHT')),
      ],
    ),
  );
}

class _Corner extends StatelessWidget {
  const _Corner(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFFFFD675),
    child: Padding(
      padding: const EdgeInsets.all(5),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.black,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );
}
