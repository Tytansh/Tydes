/// The API-provided URLs to try, in order. Keep them byte-for-byte intact:
/// query parameters may carry expiring CDN access signatures.
class VideoPlaybackSources {
  const VideoPlaybackSources({required this.primary, this.fallback});

  final String primary;
  final String? fallback;
}

VideoPlaybackSources videoPlaybackSources({
  required String url,
  required String? fallbackUrl,
  required bool isWeb,
  required bool supportsNativeHls,
}) {
  if (!isWeb) return VideoPlaybackSources(primary: url);
  final fallback =
      fallbackUrl != null && fallbackUrl.trim().isNotEmpty && fallbackUrl != url
      ? fallbackUrl
      : null;
  final isHls =
      Uri.tryParse(url)?.path.toLowerCase().endsWith('.m3u8') ?? false;
  if (isHls && supportsNativeHls) {
    return VideoPlaybackSources(primary: url, fallback: fallback);
  }
  // Preserve the existing MP4 path on browsers without native HLS. Native
  // mobile apps and legacy direct-file attachments keep their existing URL.
  return VideoPlaybackSources(primary: fallback ?? url);
}
