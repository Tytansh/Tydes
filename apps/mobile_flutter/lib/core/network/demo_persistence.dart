import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'api_models.dart';

class DemoSocialRelationshipState {
  const DemoSocialRelationshipState({
    required this.followedUserIds,
    required this.hiddenFollowingUserIds,
    required this.hiddenFollowerUserIds,
  });

  final Set<String> followedUserIds;
  final Set<String> hiddenFollowingUserIds;
  final Set<String> hiddenFollowerUserIds;
}

class DemoPersistence {
  Future<String?> loadAccessToken() async {
    try {
      final file = await _authSessionFile();
      if (!file.existsSync()) {
        return null;
      }
      final payload = jsonDecode(await file.readAsString());
      if (payload is! Map<String, dynamic>) {
        return null;
      }
      final token = payload['access_token'];
      return token is String && token.isNotEmpty ? token : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveAccessToken(String token) async {
    try {
      final file = await _authSessionFile();
      await file.writeAsString(jsonEncode({'access_token': token}));
    } catch (_) {
      // Ignore persistence failures in demo mode.
    }
  }

  Future<void> clearAccessToken() async {
    try {
      final file = await _authSessionFile();
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {
      // Ignore persistence failures in demo mode.
    }
  }

  Future<List<String>> loadFavoriteSpotIds() async {
    try {
      final file = await _favoriteSpotsFile();
      if (!file.existsSync()) {
        return [];
      }
      final payload = jsonDecode(await file.readAsString()) as List<dynamic>;
      return payload.whereType<String>().toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveFavoriteSpotIds(List<String> spotIds) async {
    try {
      final file = await _favoriteSpotsFile();
      await file.writeAsString(jsonEncode(spotIds));
    } catch (_) {
      // Ignore persistence failures in demo mode.
    }
  }

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

  Future<DemoSocialRelationshipState> loadSocialRelationships() async {
    try {
      final file = await _socialRelationshipsFile();
      if (!file.existsSync()) {
        return const DemoSocialRelationshipState(
          followedUserIds: {},
          hiddenFollowingUserIds: {},
          hiddenFollowerUserIds: {},
        );
      }
      final payload =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return DemoSocialRelationshipState(
        followedUserIds: _stringSet(payload['followed_user_ids']),
        hiddenFollowingUserIds: _stringSet(
          payload['hidden_following_user_ids'],
        ),
        hiddenFollowerUserIds: _stringSet(payload['hidden_follower_user_ids']),
      );
    } catch (_) {
      return const DemoSocialRelationshipState(
        followedUserIds: {},
        hiddenFollowingUserIds: {},
        hiddenFollowerUserIds: {},
      );
    }
  }

  Future<void> saveSocialRelationships({
    required Set<String> followedUserIds,
    required Set<String> hiddenFollowingUserIds,
    required Set<String> hiddenFollowerUserIds,
  }) async {
    try {
      final file = await _socialRelationshipsFile();
      final payload = {
        'followed_user_ids': followedUserIds.toList()..sort(),
        'hidden_following_user_ids': hiddenFollowingUserIds.toList()..sort(),
        'hidden_follower_user_ids': hiddenFollowerUserIds.toList()..sort(),
      };
      await file.writeAsString(jsonEncode(payload));
    } catch (_) {
      // Ignore persistence failures in demo mode.
    }
  }

  Set<String> _stringSet(Object? value) {
    if (value is! List) return {};
    return value.whereType<String>().toSet();
  }

  Future<List<Map<String, dynamic>>> loadDirectMessageThreadPayloads() async {
    try {
      final file = await _directMessagesFile();
      if (!file.existsSync()) {
        return [];
      }
      final payload = jsonDecode(await file.readAsString()) as List<dynamic>;
      return payload.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveDirectMessageThreadPayloads(
    List<Map<String, dynamic>> threads,
  ) async {
    try {
      final file = await _directMessagesFile();
      await file.writeAsString(jsonEncode(threads));
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

  Future<File> _authSessionFile() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/auth_session.json');
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    return file;
  }

  Future<File> _favoriteSpotsFile() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/demo_favorite_spots.json');
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    return file;
  }

  Future<File> _socialRelationshipsFile() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/demo_social_relationships.json');
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    return file;
  }

  Future<File> _directMessagesFile() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/demo_direct_messages.json');
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    return file;
  }
}
