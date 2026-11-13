import 'package:web/web.dart' as web;

bool? _nativeHlsSupported;

/// Use the browser's native player only when it advertises HLS support.
/// No player SDK, media request or user-agent sniffing is needed for this check.
bool nativeHlsPlaybackSupported() => _nativeHlsSupported ??= _detectNativeHls();

bool _detectNativeHls() {
  final video = web.HTMLVideoElement();
  return video.canPlayType('application/vnd.apple.mpegurl').isNotEmpty ||
      video.canPlayType('application/x-mpegURL').isNotEmpty;
}
