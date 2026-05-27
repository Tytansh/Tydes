import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'api_config.dart';
import 'api_models.dart';
import 'demo_persistence.dart';
import 'demo_seed.dart';

final dioProvider = Provider<Dio>((ref) {
  final persistence = ref.watch(demoPersistenceProvider);
  final dio = Dio(
    BaseOptions(
      baseUrl: ApiConfig.baseUrl,
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 18),
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await persistence.loadAccessToken();
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
    ),
  );
  return dio;
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

enum ForecastFreshness {
  fresh('fresh'),
  preview('preview');

  const ForecastFreshness(this.apiValue);

  final String apiValue;
}

class SignupResult {
  const SignupResult({
    required this.user,
    required this.verificationRequired,
    required this.verificationSentTo,
    required this.verificationHint,
  });

  final UserProfile user;
  final bool verificationRequired;
  final String? verificationSentTo;
  final String? verificationHint;
}

class SurfRepository {
  SurfRepository(this._dio, this._demoPersistence);

  final Dio _dio;
  final DemoPersistence _demoPersistence;

  Future<UserProfile> login(
    String email,
    String locale, {
    String? password,
  }) async {
    try {
      final payload = {'email': email, 'locale': locale};
      if (password != null) {
        payload['password'] = password;
      }
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/login',
        data: payload,
      );
      final data = response.data!;
      final token = data['access_token'] as String?;
      if (token != null) {
        await _demoPersistence.saveAccessToken(token);
      }
      final profile = UserProfile.fromJson(
        data['user'] as Map<String, dynamic>,
      );
      DemoSeed.me = profile;
      return profile;
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      DemoSeed.me = DemoSeed.me.copyWith(email: email, emailVerified: true);
      return DemoSeed.me;
    } catch (_) {
      DemoSeed.me = DemoSeed.me.copyWith(email: email, emailVerified: true);
      return DemoSeed.me;
    }
  }

  Future<SignupResult> signup({
    required String email,
    required String password,
    required String locale,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/signup',
        data: {'email': email, 'password': password, 'locale': locale},
      );
      final data = response.data!;
      final session = data['session'] as Map<String, dynamic>;
      final profile = UserProfile.fromJson(
        session['user'] as Map<String, dynamic>,
      );
      final token = session['access_token'] as String?;
      if (token != null) {
        await _demoPersistence.saveAccessToken(token);
      }
      DemoSeed.me = profile;
      return SignupResult(
        user: profile,
        verificationRequired: data['verification_required'] as bool? ?? false,
        verificationSentTo: data['verification_sent_to'] as String?,
        verificationHint: data['verification_hint'] as String?,
      );
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      throw StateError('Could not create account right now.');
    } catch (_) {
      DemoSeed.me = DemoSeed.me.copyWith(email: email, emailVerified: true);
      return SignupResult(
        user: DemoSeed.me,
        verificationRequired: false,
        verificationSentTo: email,
        verificationHint: null,
      );
    }
  }

  Future<UserProfile> verifyEmail({
    required String email,
    required String code,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/verify-email',
        data: {'email': email, 'code': code},
      );
      final profile = UserProfile.fromJson(response.data!);
      DemoSeed.me = profile;
      return profile;
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      throw StateError('Could not verify that code right now.');
    } catch (_) {
      DemoSeed.me = DemoSeed.me.copyWith(emailVerified: true);
      return DemoSeed.me;
    }
  }

  Future<String?> requestPasswordReset({required String email}) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/password-reset/request',
        data: {'email': email},
      );
      return response.data!['reset_hint'] as String?;
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      throw StateError('Could not send password reset email right now.');
    }
  }

  Future<UserProfile> confirmPasswordReset({
    required String email,
    required String code,
    required String password,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/password-reset/confirm',
        data: {'email': email, 'code': code, 'password': password},
      );
      final data = response.data!;
      final token = data['access_token'] as String?;
      if (token != null) {
        await _demoPersistence.saveAccessToken(token);
      }
      final profile = UserProfile.fromJson(
        data['user'] as Map<String, dynamic>,
      );
      DemoSeed.me = profile;
      return profile;
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      throw StateError('Could not reset password right now.');
    }
  }

  Future<UserProfile> logout() async {
    try {
      final response = await _dio.post<Map<String, dynamic>>('/auth/logout');
      await _demoPersistence.clearAccessToken();
      return UserProfile.fromJson(response.data!);
    } catch (_) {
      await _demoPersistence.clearAccessToken();
      return DemoSeed.me;
    }
  }

  Future<UserProfile> deleteAccount() async {
    try {
      final response = await _dio.delete<Map<String, dynamic>>('/auth/account');
      await _demoPersistence.clearAccessToken();
      return UserProfile.fromJson(response.data!);
    } catch (_) {
      await _demoPersistence.clearAccessToken();
      return DemoSeed.me;
    }
  }

  Future<UserProfile> fetchMe() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/users/me');
      final profile = UserProfile.fromJson(response.data!);
      DemoSeed.me = profile;
      await _demoPersistence.saveFavoriteSpotIds(profile.favoriteSpotIds);
      return profile;
    } catch (_) {
      final persistedFavoriteSpotIds = await _demoPersistence
          .loadFavoriteSpotIds();
      if (persistedFavoriteSpotIds.isNotEmpty) {
        DemoSeed.me = DemoSeed.me.copyWith(
          favoriteSpotIds: persistedFavoriteSpotIds,
        );
      }
      return DemoSeed.me;
    }
  }

  Future<UserProfile> updateProfile({
    required String displayName,
    required String handle,
    required String bio,
    required String surfSkill,
    required String homeRegion,
    String? avatarUrl,
  }) async {
    try {
      final response = await _dio.put<Map<String, dynamic>>(
        '/users/me',
        data: {
          'display_name': displayName,
          'handle': handle,
          'bio': bio,
          'surf_skill': surfSkill,
          'home_region': homeRegion,
          'avatar_url': avatarUrl,
        },
      );
      final profile = UserProfile.fromJson(response.data!);
      DemoSeed.me = profile;
      return profile;
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      throw StateError('Could not update profile right now.');
    } catch (_) {
      DemoSeed.me = DemoSeed.me.copyWith(
        displayName: displayName,
        handle: handle,
        bio: bio,
        surfSkill: surfSkill,
        homeRegion: homeRegion,
        avatarUrl: avatarUrl,
      );
      return DemoSeed.me;
    }
  }

  Future<UserProfile> setFreeLiveSpot(String spotId) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/users/free-live-spot',
        data: {'spot_id': spotId},
      );
      final profile = UserProfile.fromJson(response.data!);
      DemoSeed.me = profile;
      return profile;
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      throw StateError('Could not unlock live data right now.');
    } catch (_) {
      if (!DemoSeed.me.premium &&
          DemoSeed.me.freeLiveSpotId != null &&
          DemoSeed.me.freeLiveSpotId != spotId) {
        throw StateError('Free live spot already selected');
      }
      DemoSeed.me = DemoSeed.me.copyWith(freeLiveSpotId: spotId);
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

  Future<List<ForecastModel>> fetchForecasts({
    String? spotId,
    ForecastFreshness freshness = ForecastFreshness.fresh,
  }) async {
    try {
      final queryParameters = <String, dynamic>{
        'freshness': freshness.apiValue,
      };
      if (spotId != null) {
        queryParameters['spot_id'] = spotId;
      }
      final response = await _dio.get<List<dynamic>>(
        '/forecasts',
        queryParameters: queryParameters,
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

  Future<SurfWindowModel> fetchSurfWindow(String spotId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/forecasts/surf-window',
        queryParameters: {'spot_id': spotId},
      );
      return SurfWindowModel.fromJson(response.data!);
    } catch (_) {
      return SurfWindowModel(
        spotId: spotId,
        available: false,
        day: null,
        bestStartLabel: null,
        bestEndLabel: null,
        rating: 'poor',
        summary: null,
        hours: const [],
        source: 'unavailable',
        confidence: 'estimated',
        note: 'Best Time Today is unavailable right now.',
      );
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
    required bool waveEnabled,
    double? minWaveHeightM,
    required bool windEnabled,
    int? maxWindKts,
    required bool tideEnabled,
    String? tideType,
    int? tideOffsetHours,
    bool enabled = true,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/alerts',
        data: {
          'spot_id': spotId,
          'wave_enabled': waveEnabled,
          'min_wave_height_m': minWaveHeightM,
          'wind_enabled': windEnabled,
          'max_wind_kts': maxWindKts,
          'tide_enabled': tideEnabled,
          'tide_type': tideType,
          'tide_offset_hours': tideOffsetHours,
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
        waveEnabled: waveEnabled,
        minWaveHeightM: minWaveHeightM,
        windEnabled: windEnabled,
        maxWindKts: maxWindKts,
        tideEnabled: tideEnabled,
        tideType: tideType,
        tideOffsetHours: tideOffsetHours,
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
        waveEnabled: existing.waveEnabled,
        minWaveHeightM: existing.minWaveHeightM,
        windEnabled: existing.windEnabled,
        maxWindKts: existing.maxWindKts,
        tideEnabled: existing.tideEnabled,
        tideType: existing.tideType,
        tideOffsetHours: existing.tideOffsetHours,
        enabled: enabled,
        nextCheckAt: existing.nextCheckAt,
      );
      DemoSeed.alerts[index] = updated;
      await _demoPersistence.saveAlerts(DemoSeed.alerts);
      return updated;
    }
  }

  Future<AlertModel> updateAlert({
    required String alertId,
    required String spotId,
    required bool waveEnabled,
    double? minWaveHeightM,
    required bool windEnabled,
    int? maxWindKts,
    required bool tideEnabled,
    String? tideType,
    int? tideOffsetHours,
    required bool enabled,
  }) async {
    try {
      final response = await _dio.patch<Map<String, dynamic>>(
        '/alerts/$alertId',
        data: {
          'spot_id': spotId,
          'wave_enabled': waveEnabled,
          'min_wave_height_m': minWaveHeightM,
          'wind_enabled': windEnabled,
          'max_wind_kts': maxWindKts,
          'tide_enabled': tideEnabled,
          'tide_type': tideType,
          'tide_offset_hours': tideOffsetHours,
          'enabled': enabled,
        },
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
        spotId: spotId,
        waveEnabled: waveEnabled,
        minWaveHeightM: minWaveHeightM,
        windEnabled: windEnabled,
        maxWindKts: maxWindKts,
        tideEnabled: tideEnabled,
        tideType: tideType,
        tideOffsetHours: tideOffsetHours,
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
    String postType = 'general',
    String visibility = 'public',
    List<SocialMediaAttachmentModel> media = const [],
    String? meetupDate,
    String? meetupEndDate,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/social/posts',
        data: {
          'body': body,
          'spot_id': spotId,
          'post_type': postType,
          'visibility': visibility,
          'media': media.map((item) => item.toJson()).toList(),
          'meetup_date': meetupDate,
          'meetup_end_date': meetupEndDate,
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
        authorHandle: DemoSeed.me.handle,
        authorAvatarUrl: DemoSeed.me.avatarUrl,
        authorPremium: DemoSeed.me.premium,
        spotId: spotId,
        postType: postType,
        visibility: visibility,
        body: body,
        media: media,
        meetupDate: meetupDate,
        meetupEndDate: meetupEndDate,
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
      DemoSeed.posts.insert(0, post);
      return post;
    }
  }

  Future<SocialEngagementModel> fetchSocialEngagement() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/social/engagement',
      );
      return SocialEngagementModel.fromJson(response.data!);
    } catch (_) {
      return SocialEngagementModel(
        likedPostIds: const {},
        repostedPostIds: const [],
        reposts: const [],
        likedCommentIds: const {},
        rsvpPostIds: const {},
        comments: const [],
      );
    }
  }

  Future<SocialEngagementModel> setPostLike({
    required String postId,
    required bool liked,
  }) async {
    final response = liked
        ? await _dio.post<Map<String, dynamic>>('/social/posts/$postId/likes')
        : await _dio.delete<Map<String, dynamic>>(
            '/social/posts/$postId/likes',
          );
    return SocialEngagementModel.fromJson(response.data!);
  }

  Future<SocialEngagementModel> setPostRepost({
    required String postId,
    required bool reposted,
  }) async {
    final response = reposted
        ? await _dio.post<Map<String, dynamic>>('/social/posts/$postId/reposts')
        : await _dio.delete<Map<String, dynamic>>(
            '/social/posts/$postId/reposts',
          );
    return SocialEngagementModel.fromJson(response.data!);
  }

  Future<SocialEngagementModel> setEventRsvp({
    required String postId,
    required bool joined,
  }) async {
    final response = joined
        ? await _dio.post<Map<String, dynamic>>('/social/posts/$postId/rsvp')
        : await _dio.delete<Map<String, dynamic>>('/social/posts/$postId/rsvp');
    return SocialEngagementModel.fromJson(response.data!);
  }

  Future<SocialEngagementModel> createComment({
    required String postId,
    required String text,
    String? replyToCommentId,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/social/comments',
      data: {
        'post_id': postId,
        'text': text,
        'reply_to_comment_id': replyToCommentId,
      },
    );
    return SocialEngagementModel.fromJson(response.data!);
  }

  Future<SocialEngagementModel> deleteComment(String commentId) async {
    final response = await _dio.delete<Map<String, dynamic>>(
      '/social/comments/$commentId',
    );
    return SocialEngagementModel.fromJson(response.data!);
  }

  Future<SocialEngagementModel> setCommentLike({
    required String commentId,
    required bool liked,
  }) async {
    final response = liked
        ? await _dio.post<Map<String, dynamic>>(
            '/social/comments/$commentId/likes',
          )
        : await _dio.delete<Map<String, dynamic>>(
            '/social/comments/$commentId/likes',
          );
    return SocialEngagementModel.fromJson(response.data!);
  }

  Future<SocialMediaAttachmentModel> uploadPostPhoto({
    required XFile image,
    required XFile thumbnail,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/social/media',
      options: Options(
        sendTimeout: const Duration(seconds: 45),
        receiveTimeout: const Duration(seconds: 45),
      ),
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
        sendTimeout: const Duration(minutes: 2),
        receiveTimeout: const Duration(seconds: 45),
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

  Future<UserProfile> syncRevenueCatPremium() async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/billing/sync-revenuecat',
      );
      final profile = UserProfile.fromJson(
        response.data!['user'] as Map<String, dynamic>,
      );
      DemoSeed.me = profile;
      return profile;
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      throw StateError('Could not sync premium status right now.');
    } catch (_) {
      throw StateError('Could not sync premium status right now.');
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
      final favoriteSpotIds = List<String>.from(
        response.data!['favorite_spot_ids'] as List<dynamic>,
      );
      DemoSeed.me = DemoSeed.me.copyWith(favoriteSpotIds: favoriteSpotIds);
      await _demoPersistence.saveFavoriteSpotIds(favoriteSpotIds);
      return favoriteSpotIds;
    } catch (_) {
      final favoriteSpotIds = [...DemoSeed.me.favoriteSpotIds];
      if (!favoriteSpotIds.contains(spotId)) {
        favoriteSpotIds.add(spotId);
      }
      DemoSeed.me = DemoSeed.me.copyWith(favoriteSpotIds: favoriteSpotIds);
      await _demoPersistence.saveFavoriteSpotIds(favoriteSpotIds);
      return favoriteSpotIds;
    }
  }

  Future<List<String>> removeFavoriteSpot(String spotId) async {
    try {
      final response = await _dio.delete<Map<String, dynamic>>(
        '/users/favorites/$spotId',
      );
      final favoriteSpotIds = List<String>.from(
        response.data!['favorite_spot_ids'] as List<dynamic>,
      );
      DemoSeed.me = DemoSeed.me.copyWith(favoriteSpotIds: favoriteSpotIds);
      await _demoPersistence.saveFavoriteSpotIds(favoriteSpotIds);
      return favoriteSpotIds;
    } catch (_) {
      final favoriteSpotIds = [
        for (final favoriteSpotId in DemoSeed.me.favoriteSpotIds)
          if (favoriteSpotId != spotId) favoriteSpotId,
      ];
      DemoSeed.me = DemoSeed.me.copyWith(favoriteSpotIds: favoriteSpotIds);
      await _demoPersistence.saveFavoriteSpotIds(favoriteSpotIds);
      return favoriteSpotIds;
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
