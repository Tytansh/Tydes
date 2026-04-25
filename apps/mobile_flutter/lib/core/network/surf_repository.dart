import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'api_config.dart';
import 'api_models.dart';
import 'demo_persistence.dart';
import 'demo_seed.dart';

final dioProvider = Provider<Dio>((ref) {
  return Dio(
    BaseOptions(
      baseUrl: ApiConfig.baseUrl,
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 18),
    ),
  );
});

final surfRepositoryProvider = Provider<SurfRepository>((ref) {
  return SurfRepository(
    ref.watch(dioProvider),
    ref.watch(demoPersistenceProvider),
  );
});

final demoPersistenceProvider = Provider<DemoPersistence>((ref) {
  return DemoPersistence();
});

final favoriteSpotIdsProvider =
    StateNotifierProvider<FavoriteSpotIdsNotifier, Set<String>>((ref) {
      return FavoriteSpotIdsNotifier(ref.watch(surfRepositoryProvider), ref);
    });

final alertsRefreshKeyProvider = StateProvider<int>((ref) => 0);
final socialRefreshKeyProvider = StateProvider<int>((ref) => 0);

class SurfRepository {
  SurfRepository(this._dio, this._demoPersistence);

  final Dio _dio;
  final DemoPersistence _demoPersistence;

  Future<UserProfile> login(String email, String locale) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/login',
        data: {'email': email, 'locale': locale},
      );
      return UserProfile.fromJson(
        response.data!['user'] as Map<String, dynamic>,
      );
    } catch (_) {
      return DemoSeed.me;
    }
  }

  Future<UserProfile> logout() async {
    try {
      final response = await _dio.post<Map<String, dynamic>>('/auth/logout');
      return UserProfile.fromJson(response.data!);
    } catch (_) {
      return DemoSeed.me;
    }
  }

  Future<UserProfile> fetchMe() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/users/me');
      return UserProfile.fromJson(response.data!);
    } catch (_) {
      return DemoSeed.me;
    }
  }

  Future<DashboardModel> fetchDashboard() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/users/dashboard');
      return DashboardModel.fromJson(response.data!);
    } catch (_) {
      return DemoSeed.dashboard;
    }
  }

  Future<List<SpotModel>> fetchSpots() async {
    try {
      final response = await _dio.get<List<dynamic>>('/spots');
      return response.data!
          .map((item) => SpotModel.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return DemoSeed.spots;
    }
  }

  Future<SpotModel> fetchSpot(String spotId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/spots/$spotId');
      return SpotModel.fromJson(response.data!);
    } catch (_) {
      return DemoSeed.spots.firstWhere((spot) => spot.id == spotId);
    }
  }

  Future<List<ForecastModel>> fetchForecasts([String? spotId]) async {
    try {
      final response = await _dio.get<List<dynamic>>(
        '/forecasts',
        queryParameters: spotId == null ? null : {'spot_id': spotId},
      );
      return response.data!
          .map((item) => ForecastModel.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return spotId == null
          ? DemoSeed.forecasts
          : DemoSeed.forecasts.where((item) => item.spotId == spotId).toList();
    }
  }

  Future<TideForecastModel> fetchTides(String spotId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/forecasts/tides',
        queryParameters: {'spot_id': spotId},
      );
      return TideForecastModel.fromJson(response.data!);
    } catch (_) {
      return TideForecastModel.unavailable(spotId);
    }
  }

  Future<List<TripModel>> fetchTrips() async {
    try {
      final response = await _dio.get<List<dynamic>>('/trips');
      return response.data!
          .map((item) => TripModel.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return DemoSeed.trips;
    }
  }

  Future<List<AlertModel>> fetchAlerts() async {
    try {
      final response = await _dio.get<List<dynamic>>('/alerts');
      final alerts = response.data!
          .map((item) => AlertModel.fromJson(item as Map<String, dynamic>))
          .toList();
      DemoSeed.alerts
        ..clear()
        ..addAll(alerts);
      await _demoPersistence.saveAlerts(DemoSeed.alerts);
      return alerts;
    } catch (_) {
      final persistedAlerts = await _demoPersistence.loadAlerts();
      if (persistedAlerts.isNotEmpty) {
        DemoSeed.alerts
          ..clear()
          ..addAll(persistedAlerts);
      }
      return DemoSeed.alerts;
    }
  }

  Future<AlertModel> createAlert({
    required String spotId,
    required double minWaveHeightM,
    required int maxWindKts,
    bool enabled = true,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/alerts',
        data: {
          'spot_id': spotId,
          'min_wave_height_m': minWaveHeightM,
          'max_wind_kts': maxWindKts,
          'enabled': enabled,
        },
      );
      final alert = AlertModel.fromJson(response.data!);
      DemoSeed.alerts.removeWhere((item) => item.id == alert.id);
      DemoSeed.alerts.insert(0, alert);
      await _demoPersistence.saveAlerts(DemoSeed.alerts);
      return alert;
    } catch (_) {
      final alert = AlertModel(
        id: 'alert_${DateTime.now().millisecondsSinceEpoch}',
        spotId: spotId,
        minWaveHeightM: minWaveHeightM,
        maxWindKts: maxWindKts,
        enabled: enabled,
        nextCheckAt: DateTime.now()
            .toUtc()
            .add(const Duration(hours: 4))
            .toIso8601String(),
      );
      DemoSeed.alerts.insert(0, alert);
      await _demoPersistence.saveAlerts(DemoSeed.alerts);
      return alert;
    }
  }

  Future<AlertModel> updateAlertEnabled({
    required String alertId,
    required bool enabled,
  }) async {
    try {
      final response = await _dio.patch<Map<String, dynamic>>(
        '/alerts/$alertId',
        data: {'enabled': enabled},
      );
      final updated = AlertModel.fromJson(response.data!);
      final index = DemoSeed.alerts.indexWhere((item) => item.id == alertId);
      if (index != -1) {
        DemoSeed.alerts[index] = updated;
      }
      await _demoPersistence.saveAlerts(DemoSeed.alerts);
      return updated;
    } catch (_) {
      final index = DemoSeed.alerts.indexWhere((item) => item.id == alertId);
      if (index == -1) {
        throw StateError('Alert not found');
      }
      final existing = DemoSeed.alerts[index];
      final updated = AlertModel(
        id: existing.id,
        spotId: existing.spotId,
        minWaveHeightM: existing.minWaveHeightM,
        maxWindKts: existing.maxWindKts,
        enabled: enabled,
        nextCheckAt: existing.nextCheckAt,
      );
      DemoSeed.alerts[index] = updated;
      await _demoPersistence.saveAlerts(DemoSeed.alerts);
      return updated;
    }
  }

  Future<void> deleteAlert(String alertId) async {
    try {
      await _dio.delete<Map<String, dynamic>>('/alerts/$alertId');
    } catch (_) {
      // Preserve demo usability when the API is unavailable.
    } finally {
      DemoSeed.alerts.removeWhere((item) => item.id == alertId);
      await _demoPersistence.saveAlerts(DemoSeed.alerts);
    }
  }

  Future<void> joinWaitlist(String email) async {
    try {
      await _dio.post<Map<String, dynamic>>(
        '/auth/waitlist',
        data: {'email': email},
      );
    } catch (_) {
      // Keep the UI friendly even if the backend isn't reachable yet.
    }
  }

  Future<List<FriendProfileModel>> fetchFriends() async {
    try {
      final response = await _dio.get<List<dynamic>>('/social/friends');
      return response.data!
          .map(
            (item) => FriendProfileModel.fromJson(item as Map<String, dynamic>),
          )
          .toList();
    } catch (_) {
      return DemoSeed.friends;
    }
  }

  Future<List<SocialPostModel>> fetchSocialPosts() async {
    try {
      final response = await _dio.get<List<dynamic>>('/social/posts');
      final posts = response.data!
          .map((item) => SocialPostModel.fromJson(item as Map<String, dynamic>))
          .toList();
      DemoSeed.posts
        ..clear()
        ..addAll(posts);
      return posts;
    } catch (_) {
      return DemoSeed.posts;
    }
  }

  Future<SocialPostModel> createSocialPost({
    required String body,
    String? spotId,
    String visibility = 'public',
    List<SocialMediaAttachmentModel> media = const [],
    String? meetupDate,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/social/posts',
        data: {
          'body': body,
          'spot_id': spotId,
          'post_type': 'general',
          'visibility': visibility,
          'media': media.map((item) => item.toJson()).toList(),
          'meetup_date': meetupDate,
        },
      );
      final post = SocialPostModel.fromJson(response.data!);
      DemoSeed.posts.insert(0, post);
      return post;
    } catch (_) {
      final post = SocialPostModel(
        id: 'post_${DateTime.now().millisecondsSinceEpoch}',
        userId: DemoSeed.me.id,
        authorName: DemoSeed.me.displayName,
        spotId: spotId,
        postType: 'general',
        visibility: visibility,
        body: body,
        media: media,
        meetupDate: meetupDate,
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
      DemoSeed.posts.insert(0, post);
      return post;
    }
  }

  Future<SocialMediaAttachmentModel> uploadPostPhoto({
    required XFile image,
    required XFile thumbnail,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/social/media',
      data: FormData.fromMap({
        'file': await MultipartFile.fromFile(image.path, filename: image.name),
        'thumbnail': await MultipartFile.fromFile(
          thumbnail.path,
          filename: thumbnail.name,
        ),
      }),
    );
    return SocialMediaAttachmentModel.fromJson(response.data!);
  }

  Future<SocialMediaAttachmentModel> uploadPostVideo({
    required XFile video,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/social/media',
      options: Options(
        sendTimeout: const Duration(minutes: 5),
        receiveTimeout: const Duration(minutes: 2),
      ),
      data: FormData.fromMap({
        'file': await MultipartFile.fromFile(video.path, filename: video.name),
      }),
    );
    return SocialMediaAttachmentModel.fromJson(response.data!);
  }

  Future<List<BillingPlanModel>> fetchPlans() async {
    try {
      final response = await _dio.get<List<dynamic>>('/billing/plans');
      return response.data!
          .map(
            (item) => BillingPlanModel.fromJson(item as Map<String, dynamic>),
          )
          .toList();
    } catch (_) {
      return DemoSeed.plans;
    }
  }

  Future<List<AdModel>> fetchAds() async {
    try {
      final response = await _dio.get<List<dynamic>>(
        '/ads',
        queryParameters: {'placement': 'home_feed'},
      );
      return response.data!
          .map((item) => AdModel.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return DemoSeed.ads;
    }
  }

  Future<List<String>> addFavoriteSpot(String spotId) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/users/favorites',
        data: {'spot_id': spotId},
      );
      return List<String>.from(
        response.data!['favorite_spot_ids'] as List<dynamic>,
      );
    } catch (_) {
      if (!DemoSeed.me.favoriteSpotIds.contains(spotId)) {
        DemoSeed.me.favoriteSpotIds.add(spotId);
      }
      return DemoSeed.me.favoriteSpotIds;
    }
  }

  Future<List<String>> removeFavoriteSpot(String spotId) async {
    try {
      final response = await _dio.delete<Map<String, dynamic>>(
        '/users/favorites/$spotId',
      );
      return List<String>.from(
        response.data!['favorite_spot_ids'] as List<dynamic>,
      );
    } catch (_) {
      DemoSeed.me.favoriteSpotIds.remove(spotId);
      return DemoSeed.me.favoriteSpotIds;
    }
  }
}

class FavoriteSpotIdsNotifier extends StateNotifier<Set<String>> {
  FavoriteSpotIdsNotifier(this._repository, Ref ref)
    : super(DemoSeed.me.favoriteSpotIds.toSet());

  final SurfRepository _repository;

  void replaceAll(Iterable<String> spotIds) {
    state = spotIds.toSet();
  }

  Future<void> toggle(String spotId) async {
    final previous = state;
    final shouldAdd = !state.contains(spotId);
    state = shouldAdd ? {...state, spotId} : {...state}
      ..remove(spotId);

    try {
      final nextIds = shouldAdd
          ? await _repository.addFavoriteSpot(spotId)
          : await _repository.removeFavoriteSpot(spotId);
      state = nextIds.toSet();
    } catch (_) {
      state = previous;
    }
  }
}
