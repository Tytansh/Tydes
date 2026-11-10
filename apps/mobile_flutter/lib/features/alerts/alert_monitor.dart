import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../../core/notifications/notification_service.dart';

final alertMonitorProvider = Provider<AlertMonitor>((ref) {
  return AlertMonitor(
    repository: ref.watch(surfRepositoryProvider),
    notifications: ref.watch(notificationServiceProvider),
  );
});

class AlertMonitor {
  AlertMonitor({
    required SurfRepository repository,
    required NotificationService notifications,
  }) : _repository = repository,
       _notifications = notifications;

  final SurfRepository _repository;
  final NotificationService _notifications;
  final Map<String, String> _seenTriggerTokens = <String, String>{};

  Timer? _timer;
  bool _checking = false;
  int _generation = 0;

  Future<void> initialize() async {
    final generation = _generation;
    try {
      await _notifications.initialize();
    } catch (_) {
      // A platform without local notifications must not break browsing.
      return;
    }
    if (generation != _generation) return;
    _timer ??= Timer.periodic(const Duration(minutes: 2), (_) => checkNow());
    await checkNow();
  }

  Future<void> checkNow() async {
    if (_checking) return;
    final generation = _generation;
    _checking = true;
    try {
      final alerts = await _repository.fetchAlerts();
      if (generation != _generation) return;
      final spots = await _repository.fetchSpots();
      final spotNames = {for (final spot in spots) spot.id: spot.name};

      for (final alert in alerts) {
        if (generation != _generation) return;
        final token = alert.lastTriggeredAt ?? alert.nextCheckAt;
        if (alert.enabled && alert.status == 'triggered') {
          final previous = _seenTriggerTokens[alert.id];
          if (previous != token) {
            final spotName = spotNames[alert.spotId] ?? 'Surf alert';
            await _notifications.showAlertTriggered(
              id: alert.id.hashCode,
              title: '$spotName is on',
              body: alert.statusReason ?? _alertNotificationBody(alert),
            );
            _seenTriggerTokens[alert.id] = token;
          }
        } else {
          _seenTriggerTokens.remove(alert.id);
        }
      }
    } catch (_) {
      // Failed reads must not trigger notifications from cached/demo alerts.
      // The next scheduled or explicitly requested check will retry.
    } finally {
      _checking = false;
    }
  }

  void dispose() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _seenTriggerTokens.clear();
  }
}

String _alertNotificationBody(AlertModel alert) {
  final parts = <String>[];
  if (alert.waveEnabled && alert.minWaveHeightM != null) {
    parts.add('wave at least ${alert.minWaveHeightM}m');
  }
  if (alert.windEnabled && alert.maxWindKts != null) {
    parts.add('wind below ${alert.maxWindKts}kts');
  }
  if (alert.tideEnabled &&
      alert.tideType != null &&
      alert.tideOffsetHours != null) {
    final tideLabel = alert.tideType == 'high' ? 'high tide' : 'low tide';
    if (alert.tideOffsetHours == 0) {
      parts.add('at $tideLabel');
    } else if (alert.tideOffsetHours! < 0) {
      parts.add('${alert.tideOffsetHours!.abs()}h before $tideLabel');
    } else {
      parts.add('${alert.tideOffsetHours!.abs()}h after $tideLabel');
    }
  }
  if (parts.isEmpty) {
    return 'Conditions match your alert right now.';
  }
  return 'Conditions match: ${parts.join(' • ')}';
}
