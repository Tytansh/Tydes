/// The API-provided URLs to try, in order. Keep them byte-for-byte intact:
/// query parameters may carry expiring CDN access signatures.
class VideoPlaybackSources {
  const VideoPlaybackSources({required this.primary, this.fallback});

  final String primary;
  final String? fallback;
}

/// Native players do not automatically send the website's Referer. Bunny's
/// configured hotlink protection still applies outside a browser, so identify
/// our own site for its HTTPS CDN only. Browsers supply their real Referer;
/// private media tokens and all source URLs remain unchanged.
Map<String, String> videoPlaybackHeaders({
  required String url,
  required bool isWeb,
}) {
  if (isWeb) return const {};
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      !uri.host.endsWith('.b-cdn.net') ||
      uri.host.length <= '.b-cdn.net'.length) {
    return const {};
  }
  return const {'Referer': 'https://tydes.io/'};
}

VideoPlaybackSources videoPlaybackSources({
  required String url,
  required String? fallbackUrl,
  required bool isWeb,
  required bool supportsNativeHls,
}) {
  final fallback =
      fallbackUrl != null && fallbackUrl.trim().isNotEmpty && fallbackUrl != url
      ? fallbackUrl
      : null;
  // AVPlayer supports HLS, but a transient playlist/segment failure must still
  // be able to try the API-supplied MP4 once, just like Safari. Do not discard
  // the alternative on native; the player owns bounded failover and retries.
  if (!isWeb) {
    return VideoPlaybackSources(primary: url, fallback: fallback);
  }
  final isHls =
      Uri.tryParse(url)?.path.toLowerCase().endsWith('.m3u8') ?? false;
  if (isHls && supportsNativeHls) {
    return VideoPlaybackSources(primary: url, fallback: fallback);
  }
  // Preserve the existing MP4 path on browsers without native HLS. Native
  // mobile apps and legacy direct-file attachments keep their existing URL.
  return VideoPlaybackSources(primary: fallback ?? url);
}
