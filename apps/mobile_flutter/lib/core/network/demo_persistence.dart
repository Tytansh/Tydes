import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'api_models.dart';

class DemoPersistence {
  Future<List<AlertModel>> loadAlerts() async {
    try {
      final file = await _alertsFile();
      if (!file.existsSync()) {
        return [];
      }
      final payload = jsonDecode(await file.readAsString()) as List<dynamic>;
      return payload
          .map((item) => AlertModel.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAlerts(List<AlertModel> alerts) async {
    try {
      final file = await _alertsFile();
      final payload = alerts
          .map(
            (alert) => {
              'id': alert.id,
              'spot_id': alert.spotId,
              'wave_enabled': alert.waveEnabled,
              'min_wave_height_m': alert.minWaveHeightM,
              'wind_enabled': alert.windEnabled,
              'max_wind_kts': alert.maxWindKts,
              'tide_enabled': alert.tideEnabled,
              'tide_type': alert.tideType,
              'tide_offset_hours': alert.tideOffsetHours,
              'enabled': alert.enabled,
              'status': alert.status,
              'status_reason': alert.statusReason,
              'last_evaluated_at': alert.lastEvaluatedAt,
              'last_triggered_at': alert.lastTriggeredAt,
              'next_check_at': alert.nextCheckAt,
            },
          )
          .toList();
      await file.writeAsString(jsonEncode(payload));
    } catch (_) {
      // Ignore persistence failures in demo mode.
    }
  }

  Future<File> _alertsFile() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/demo_alerts.json');
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    return file;
  }
}
