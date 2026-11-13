import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_flutter/core/media/native_hls_support.dart';
import 'package:mobile_flutter/core/media/video_playback_sources.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/widgets/retained_tab_stack.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

import 'video_preview_telemetry_stub.dart'
    if (dart.library.js_interop) 'video_preview_telemetry_web.dart';

const _videoUrl = String.fromEnvironment('VIDEO_PREVIEW_URL');
const _fallbackUrl = String.fromEnvironment('FALLBACK_PREVIEW_URL');
const _forceMp4 = bool.fromEnvironment('FORCE_MP4_PREVIEW');

void main() {
  runApp(const ProviderScope(child: _PlaybackVerificationApp()));
}

class _PlaybackVerificationApp extends StatefulWidget {
  const _PlaybackVerificationApp();

  @override
  State<_PlaybackVerificationApp> createState() =>
      _PlaybackVerificationAppState();
}

class _PlaybackVerificationAppState extends State<_PlaybackVerificationApp> {
  int _tab = 0;
  late final VideoPreviewTelemetry _telemetry;

  @override
  void initState() {
    super.initState();
    _telemetry = VideoPreviewTelemetry();
  }

  @override
  void dispose() {
    _telemetry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'TYDES playback verification',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      scaffoldBackgroundColor: const Color(0xFFFFF8D9),
    ),
    home: Scaffold(
      appBar: AppBar(title: const Text('TYDES playback verification')),
      body: Column(
        children: [
          ValueListenableBuilder<String>(
            valueListenable: _telemetry,
            builder: (context, value, _) => Padding(
              padding: const EdgeInsets.all(8),
              child: Text(value, style: const TextStyle(fontSize: 12)),
            ),
          ),
          Expanded(
            child: RetainedTabStack(
              index: _tab,
              children: const [
                _VerificationFeed(),
                Center(
                  child: Text('Profile — the hidden feed must stay silent.'),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (value) => setState(() => _tab = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.view_list), label: 'Feed'),
          NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    ),
  );
}

class _VerificationFeed extends StatelessWidget {
  const _VerificationFeed();

  @override
  Widget build(BuildContext context) {
    if (_videoUrl.isEmpty) {
      return const Center(child: Text('VIDEO_PREVIEW_URL is required.'));
    }
    return ListView(
      cacheExtent: 1800,
      padding: const EdgeInsets.all(16),
      children: const [
        Text(
          'Test-only production carousel. Scroll between clips, then switch tabs.',
        ),
        SizedBox(height: 16),
        _VerificationClip(label: 'Clip A'),
        SizedBox(height: 650),
        _VerificationClip(label: 'Clip B'),
        SizedBox(height: 650),
      ],
    );
  }
}

class _VerificationClip extends StatelessWidget {
  const _VerificationClip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final url = _forceMp4 && _fallbackUrl.isNotEmpty ? _fallbackUrl : _videoUrl;
    final fallbackUrl = !_forceMp4 && _fallbackUrl.isNotEmpty
        ? _fallbackUrl
        : null;
    final sources = videoPlaybackSources(
      url: url,
      fallbackUrl: fallbackUrl,
      isWeb: true,
      supportsNativeHls: nativeHlsPlaybackSupported(),
    );
    final selection =
        Uri.tryParse(sources.primary)?.path.endsWith('.m3u8') == true
        ? 'HLS'
        : 'direct file / MP4';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleLarge),
        Text('Selected: $selection${_forceMp4 ? ' (baseline forced)' : ''}'),
        const SizedBox(height: 8),
        SizedBox(
          height: 280,
          child: SocialPostMediaCarousel(
            media: [
              SocialMediaAttachmentModel(
                id: 'test-only-$label',
                mediaType: 'video',
                url: url,
                thumbnailUrl: '',
                fallbackUrl: fallbackUrl,
                width: 1280,
                height: 720,
                altText: 'Synthetic playback test',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
