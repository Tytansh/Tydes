import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Read-only diagnostics for the test harness, never imported by production.
/// Counts observed waiting events; does not call play/pause or alter sources.
class VideoPreviewTelemetry extends ValueNotifier<String> {
  VideoPreviewTelemetry() : super('Waiting for an HTML video element…') {
    _timer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _sample(),
    );
  }

  late final Timer _timer;
  final _waiting = <web.HTMLVideoElement, int>{};
  final _subscriptions =
      <web.HTMLVideoElement, StreamSubscription<web.Event>>{};

  void _sample() {
    final nodes = web.document.querySelectorAll('video');
    final lines = <String>[];
    final current = <web.HTMLVideoElement>{};
    for (var i = 0; i < nodes.length; i++) {
      final video = nodes.item(i) as web.HTMLVideoElement;
      current.add(video);
      if (!_subscriptions.containsKey(video)) {
        _waiting[video] = 0;
        _subscriptions[video] = video.onWaiting.listen((_) {
          _waiting[video] = (_waiting[video] ?? 0) + 1;
        });
      }
      final source = video.currentSrc.isNotEmpty ? video.currentSrc : video.src;
      final path = Uri.tryParse(source)?.path.toLowerCase() ?? '';
      final type = path.endsWith('.m3u8') ? 'HLS' : 'MP4/direct';
      final buffered = video.buffered.length > 0
          ? (video.buffered.end(video.buffered.length - 1) - video.currentTime)
                .clamp(0, double.infinity)
                .toStringAsFixed(1)
          : '0.0';
      lines.add(
        '$type · ready ${video.readyState} · ${video.paused ? 'paused' : 'playing'}'
        ' · ${video.muted ? 'muted' : 'sound'} · ${video.currentTime.toStringAsFixed(1)}s'
        ' · buffer ${buffered}s · waits ${_waiting[video]}',
      );
    }
    for (final video in _subscriptions.keys.toList()) {
      if (!current.contains(video)) {
        unawaited(_subscriptions.remove(video)!.cancel());
        _waiting.remove(video);
      }
    }
    value = lines.isEmpty
        ? 'No mounted HTML video. Diagnostics are not a time-to-first-frame measurement.'
        : lines.join('\n');
  }

  @override
  void dispose() {
    _timer.cancel();
    for (final subscription in _subscriptions.values) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}
