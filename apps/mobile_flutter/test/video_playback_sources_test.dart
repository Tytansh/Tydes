import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/media/video_playback_sources.dart';

void main() {
  const hls =
      'https://video.example.invalid/clip/playlist.m3u8?token=A%2FB&expires=123';
  const mp4 =
      'https://video.example.invalid/clip/play_720p.mp4?token=C%2FD&expires=456';

  test('native HLS web playback retains exact primary and fallback URLs', () {
    final sources = videoPlaybackSources(
      url: hls,
      fallbackUrl: mp4,
      isWeb: true,
      supportsNativeHls: true,
    );
    expect(sources.primary, hls);
    expect(sources.fallback, mp4);
  });

  test('web without native HLS retains the existing MP4 path', () {
    final sources = videoPlaybackSources(
      url: hls,
      fallbackUrl: mp4,
      isWeb: true,
      supportsNativeHls: false,
    );
    expect(sources.primary, mp4);
    expect(sources.fallback, isNull);
  });

  test('native Flutter keeps its original stream selection', () {
    final sources = videoPlaybackSources(
      url: hls,
      fallbackUrl: mp4,
      isWeb: false,
      supportsNativeHls: false,
    );
    expect(sources.primary, hls);
    expect(sources.fallback, isNull);
  });

  test('legacy direct files without alternatives are unchanged', () {
    for (final url in [
      'https://media.example.invalid/original.mov?signature=a%2Fb',
      'https://media.example.invalid/video.mp4',
    ]) {
      final sources = videoPlaybackSources(
        url: url,
        fallbackUrl: null,
        isWeb: true,
        supportsNativeHls: true,
      );
      expect(sources.primary, url);
      expect(sources.fallback, isNull);
    }
  });

  test('non-HLS web alternatives retain existing selection', () {
    final sources = videoPlaybackSources(
      url: 'https://media.example.invalid/original.mov',
      fallbackUrl: mp4,
      isWeb: true,
      supportsNativeHls: true,
    );
    expect(sources.primary, mp4);
    expect(sources.fallback, isNull);
  });

  test('empty and duplicate alternatives never create a retry loop', () {
    for (final fallback in [null, '', '   ', hls]) {
      final sources = videoPlaybackSources(
        url: hls,
        fallbackUrl: fallback,
        isWeb: true,
        supportsNativeHls: true,
      );
      expect(sources.primary, hls);
      expect(sources.fallback, isNull);
    }
  });
}
