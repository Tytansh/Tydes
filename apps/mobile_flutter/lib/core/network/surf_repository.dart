import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../moderation/content_moderation.dart';
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
        if (token != null && !options.headers.containsKey('Authorization')) {
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
  final Dio _directUploadDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 45),
      sendTimeout: const Duration(minutes: 10),
      receiveTimeout: const Duration(minutes: 5),
    ),
  );

  Future<Map<String, dynamic>> fetchGoogleAuthConfig() async {
    return (await _dio.get<Map<String, dynamic>>('/auth/google/config')).data!;
  }

  Future<Map<String, dynamic>> createGoogleAuthChallenge(
    String verifierHash,
  ) async {
    return (await _dio.post<Map<String, dynamic>>(
      '/auth/google/challenge',
      data: {'verifier_hash': verifierHash},
    )).data!;
  }

  Future<SignupResult> loginWithGoogle({
    required String credential,
    required String challengeId,
    required String verifier,
    required String locale,
    bool allowSignup = false,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/google',
        data: {
          'credential': credential,
          'challenge_id': challengeId,
          'verifier': verifier,
          'locale': locale,
          'allow_signup': allowSignup,
        },
      );
      final data = response.data!;
      final session = data['session'] as Map<String, dynamic>;
      final profile = UserProfile.fromJson(
        session['user'] as Map<String, dynamic>,
      );
      final token = session['access_token'] as String?;
      if (token == null || token.isEmpty) {
        throw StateError('Google did not complete sign-in.');
      }
      await _demoPersistence.saveAccessToken(token);
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
      throw StateError('Could not sign in with Google right now.');
    }
  }

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
      if (token == null || token.isEmpty) {
        throw StateError('Sign-in did not complete.');
      }
      await _demoPersistence.saveAccessToken(token);
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
      throw StateError('Could not sign in right now.');
    } catch (_) {
      throw StateError('Could not sign in right now.');
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
      throw StateError('Could not create account right now.');
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
      throw StateError('Could not verify that code right now.');
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
    final token = await _demoPersistence.loadAccessToken();
    if (token == null) return DemoSeed.me;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/auth/logout',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      await _demoPersistence.clearAccessTokenIfMatches(token);
      return UserProfile.fromJson(response.data!);
    } catch (_) {
      await _demoPersistence.clearAccessTokenIfMatches(token);
      return DemoSeed.me;
    }
  }

  Future<UserProfile> deleteAccount() async {
    final token = await _demoPersistence.loadAccessToken();
    if (token == null) {
      throw StateError('Sign in before deleting your account.');
    }
    try {
      final response = await _dio.delete<Map<String, dynamic>>(
        '/auth/account',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final profile = UserProfile.fromJson(response.data!);
      await _demoPersistence.clearAccessTokenIfMatches(token);
      return profile;
    } on DioException {
      throw StateError(
        'Account deletion could not be confirmed. You are still signed in. Please try again.',
      );
    }
  }

  Future<UserProfile> fetchMe() async {
    final token = await _demoPersistence.loadAccessToken();
    if (token == null) {
      throw StateError('Session expired. Please sign in again.');
    }
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/users/me',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if (await _demoPersistence.loadAccessToken() != token) return fetchMe();
      final profile = UserProfile.fromJson(response.data!);
      DemoSeed.me = profile;
      await _demoPersistence.saveFavoriteSpotIds(profile.favoriteSpotIds);
      return profile;
    } on DioException catch (error) {
      if (await _demoPersistence.loadAccessToken() != token) return fetchMe();
      final statusCode = error.response?.statusCode;
      if (statusCode == 401 || statusCode == 403) {
        if (!await _demoPersistence.clearAccessTokenIfMatches(token)) {
          return fetchMe();
        }
        throw StateError('Session expired. Please sign in again.');
      }
      final persistedFavoriteSpotIds = await _demoPersistence
          .loadFavoriteSpotIds();
      if (persistedFavoriteSpotIds.isNotEmpty) {
        DemoSeed.me = DemoSeed.me.copyWith(
          favoriteSpotIds: persistedFavoriteSpotIds,
        );
      }
      return DemoSeed.me;
    } catch (_) {
      if (await _demoPersistence.loadAccessToken() != token) return fetchMe();
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
    String? avatarMediaId,
    String? coverUrl,
    String? coverMediaId,
  }) async {
    ensureAllowedContent([displayName, bio, homeRegion]);
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
          'avatar_media_id': avatarMediaId,
          'cover_url': coverUrl,
          'cover_media_id': coverMediaId,
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
        coverUrl: coverUrl,
        clearCoverUrl: coverUrl == null,
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
          DemoSeed.me.freeLiveSpotId != spotId &&
          !DemoSeed.me.canChangeFreeLiveSpot(DateTime.now())) {
        final remaining = DemoSeed.me.freeLiveSpotChangeRemaining(
          DateTime.now(),
        );
        throw StateError(
          'You can change your free premium break again in ${_friendlyDuration(remaining)}.',
        );
      }
      DemoSeed.me = DemoSeed.me.copyWith(
        freeLiveSpotId: spotId,
        freeLiveSpotChangedAt: DateTime.now(),
      );
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
      final response = await _fetchForecastResponse(queryParameters);
      return response.data!
          .map((item) => ForecastModel.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return spotId == null
          ? DemoSeed.forecasts
          : DemoSeed.forecasts.where((item) => item.spotId == spotId).toList();
    }
  }

  Future<Response<List<dynamic>>> _fetchForecastResponse(
    Map<String, dynamic> queryParameters,
  ) async {
    const timeout = Duration(seconds: 40);
    try {
      return await _dio.get<List<dynamic>>(
        '/forecasts',
        queryParameters: queryParameters,
        options: Options(receiveTimeout: timeout),
      );
    } on DioException catch (error) {
      if (!_shouldRetryForecast(error)) rethrow;
      return _dio.get<List<dynamic>>(
        '/forecasts',
        queryParameters: queryParameters,
        options: Options(receiveTimeout: timeout),
      );
    }
  }

  bool _shouldRetryForecast(DioException error) {
    final statusCode = error.response?.statusCode;
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504;
  }

  Future<NextSwellModel> fetchNextSwell() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/forecasts/next-swell',
      );
      return NextSwellModel.fromJson(response.data!);
    } catch (_) {
      return NextSwellModel.unavailable(
        summary: 'The next-swell scan is unavailable right now.',
      );
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
    final response = await _dio.get<List<dynamic>>('/alerts');
    return response.data!
        .map((item) => AlertModel.fromJson(item as Map<String, dynamic>))
        .toList();
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
    return AlertModel.fromJson(response.data!);
  }

  Future<AlertModel> updateAlertEnabled({
    required String alertId,
    required bool enabled,
  }) async {
    final response = await _dio.patch<Map<String, dynamic>>(
      '/alerts/$alertId',
      data: {'enabled': enabled},
    );
    final updated = AlertModel.fromJson(response.data!);
    if (updated.id != alertId) {
      throw StateError('The alert update could not be confirmed.');
    }
    return updated;
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
    if (updated.id != alertId) {
      throw StateError('The alert update could not be confirmed.');
    }
    return updated;
  }

  Future<void> deleteAlert(String alertId) async {
    final response = await _dio.delete<Map<String, dynamic>>(
      '/alerts/$alertId',
    );
    if (response.data?['deleted'] != true) {
      throw StateError('The alert deletion could not be confirmed.');
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

  Future<List<SocialPostModel>> fetchMapEvents() async {
    final response = await _dio.get<List<dynamic>>('/social/events');
    return response.data!
        .map((item) => SocialPostModel.fromJson(item as Map<String, dynamic>))
        .toList();
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
    ensureAllowedContent([body]);
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
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      throw StateError('Could not create post right now.');
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

  Future<void> deleteSocialPost(String postId) async {
    try {
      await _dio.delete<Map<String, dynamic>>('/social/posts/$postId');
      DemoSeed.posts.removeWhere((post) => post.id == postId);
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      throw StateError('Could not delete this post right now.');
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

  Future<SocialRelationshipModel> fetchSocialRelationships() async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/social/relationships',
    );
    return SocialRelationshipModel.fromJson(response.data!);
  }

  Future<List<SocialProfileModel>> fetchSocialProfiles() async {
    final response = await _dio.get<List<dynamic>>('/social/profiles');
    return response.data!
        .map(
          (item) => SocialProfileModel.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<List<SocialProfileModel>> fetchBlockedSocialProfiles() async {
    final response = await _dio.get<List<dynamic>>('/social/blocked-profiles');
    return response.data!
        .map(
          (item) => SocialProfileModel.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<List<AdminUserAccount>> fetchAdminUsers() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/admin/dashboard/users',
      );
      return (response.data?['users'] as List<dynamic>? ?? const [])
          .map(
            (item) => AdminUserAccount.fromJson(item as Map<String, dynamic>),
          )
          .toList();
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      throw StateError('Could not load accounts right now.');
    }
  }

  Future<List<AdminReport>> fetchAdminReports() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/admin/dashboard/reports',
      );
      return (response.data?['reports'] as List<dynamic>? ?? const [])
          .map((item) => AdminReport.fromJson(item as Map<String, dynamic>))
          .toList();
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      throw StateError('Could not load reports right now.');
    }
  }

  Future<AdminUserAccount> updateAdminUserAccess({
    required String userId,
    bool? premium,
    bool? banned,
  }) async {
    try {
      final payload = <String, dynamic>{};
      if (premium != null) payload['premium'] = premium;
      if (banned != null) payload['banned'] = banned;
      final response = await _dio.patch<Map<String, dynamic>>(
        '/admin/dashboard/users/$userId',
        data: payload,
      );
      return AdminUserAccount.fromJson(response.data!);
    } on DioException catch (error) {
      final detail = error.response?.data;
      if (detail is Map<String, dynamic> && detail['detail'] is String) {
        throw StateError(detail['detail'] as String);
      }
      throw StateError('Could not update this account right now.');
    }
  }

  Future<List<SocialNotificationModel>> fetchSocialNotifications() async {
    final response = await _dio.get<List<dynamic>>('/social/notifications');
    return response.data!
        .map(
          (item) =>
              SocialNotificationModel.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<SocialRelationshipModel> setUserFollow({
    required String userId,
    required bool following,
  }) async {
    final response = following
        ? await _dio.post<Map<String, dynamic>>('/social/follows/$userId')
        : await _dio.delete<Map<String, dynamic>>('/social/follows/$userId');
    return SocialRelationshipModel.fromJson(response.data!);
  }

  Future<SocialRelationshipModel> removeFollower({
    required String userId,
  }) async {
    final response = await _dio.delete<Map<String, dynamic>>(
      '/social/followers/$userId',
    );
    return SocialRelationshipModel.fromJson(response.data!);
  }

  Future<SocialRelationshipModel> setUserBlocked({
    required String userId,
    required bool blocked,
  }) async {
    final response = blocked
        ? await _dio.post<Map<String, dynamic>>('/social/blocks/$userId')
        : await _dio.delete<Map<String, dynamic>>('/social/blocks/$userId');
    return SocialRelationshipModel.fromJson(response.data!);
  }

  Future<void> reportSocialContent({
    required String targetType,
    required String targetId,
    String reason = '',
  }) async {
    await _dio.post<Map<String, dynamic>>(
      '/social/reports',
      data: {
        'target_type': targetType,
        'target_id': targetId,
        'reason': reason,
      },
    );
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

  Future<List<EventAttendeeModel>> fetchEventAttendees(String postId) async {
    final response = await _dio.get<List<dynamic>>(
      '/social/posts/$postId/attendees',
    );
    return response.data!
        .map(
          (item) => EventAttendeeModel.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<List<EventChatMessageModel>> fetchEventChat(String postId) async {
    final response = await _dio.get<List<dynamic>>(
      '/social/posts/$postId/chat',
    );
    return response.data!
        .map(
          (item) =>
              EventChatMessageModel.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<EventChatMessageModel> sendEventChatMessage({
    required String postId,
    required String text,
  }) async {
    ensureAllowedContent([text]);
    final response = await _dio.post<Map<String, dynamic>>(
      '/social/posts/$postId/chat',
      data: {'text': text.trim()},
    );
    return EventChatMessageModel.fromJson(response.data!);
  }

  Future<SocialEngagementModel> createComment({
    required String postId,
    required String text,
    String? replyToCommentId,
  }) async {
    ensureAllowedContent([text]);
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
    ProgressCallback? onSendProgress,
  }) async {
    try {
      return await _uploadPostMediaDirect(
        mediaType: 'photo',
        file: image,
        thumbnail: thumbnail,
        onSendProgress: onSendProgress,
      );
    } on DioException catch (error) {
      if (!_directUploadUnavailable(error)) rethrow;
    }
    return _uploadPostPhotoRelay(
      image: image,
      thumbnail: thumbnail,
      onSendProgress: onSendProgress,
    );
  }

  Future<SocialMediaAttachmentModel> _uploadPostPhotoRelay({
    required XFile image,
    required XFile thumbnail,
    ProgressCallback? onSendProgress,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/social/media',
      options: Options(
        sendTimeout: const Duration(minutes: 2),
        receiveTimeout: const Duration(minutes: 2),
      ),
      onSendProgress: onSendProgress,
      data: FormData.fromMap({
        'file': await _multipartFile(image),
        'thumbnail': await _multipartFile(thumbnail),
      }),
    );
    return SocialMediaAttachmentModel.fromJson(response.data!);
  }

  Future<SocialMediaAttachmentModel> uploadPostVideo({
    required XFile video,
    XFile? thumbnail,
    ProgressCallback? onSendProgress,
  }) async {
    try {
      return await _uploadPostMediaDirect(
        mediaType: 'video',
        file: video,
        thumbnail: thumbnail,
        onSendProgress: onSendProgress,
      );
    } on DioException catch (error) {
      if (!_directUploadUnavailable(error)) rethrow;
    }
    return _uploadPostVideoRelay(
      video: video,
      thumbnail: thumbnail,
      onSendProgress: onSendProgress,
    );
  }

  Future<SocialMediaAttachmentModel> _uploadPostVideoRelay({
    required XFile video,
    XFile? thumbnail,
    ProgressCallback? onSendProgress,
  }) async {
    final formData = <String, dynamic>{'file': await _multipartFile(video)};
    if (thumbnail != null) {
      formData['thumbnail'] = await _multipartFile(thumbnail);
    }
    final response = await _dio.post<Map<String, dynamic>>(
      '/social/media',
      options: Options(
        sendTimeout: const Duration(minutes: 10),
        receiveTimeout: const Duration(minutes: 2),
      ),
      onSendProgress: onSendProgress,
      data: FormData.fromMap(formData),
    );
    return SocialMediaAttachmentModel.fromJson(response.data!);
  }

  Future<SocialMediaAttachmentModel> _uploadPostMediaDirect({
    required String mediaType,
    required XFile file,
    XFile? thumbnail,
    ProgressCallback? onSendProgress,
  }) async {
    final fileBytes = await file.length();
    final thumbnailBytes = thumbnail == null ? 0 : await thumbnail.length();
    final contentType = _mediaContentType(file, mediaType: mediaType);
    final thumbnailContentType = thumbnail == null
        ? null
        : _mediaContentType(thumbnail, mediaType: 'photo');
    String? reservationId;
    var uploadedToStorage = false;
    try {
      final reservationResponse = await _dio.post<Map<String, dynamic>>(
        '/social/media/uploads',
        options: Options(
          connectTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(minutes: 1),
          receiveTimeout: const Duration(minutes: 1),
        ),
        data: {
          'media_type': mediaType,
          'content_type': contentType,
          'size_bytes': fileBytes,
          'thumbnail_content_type': thumbnailContentType,
          'thumbnail_size_bytes': thumbnailBytes,
          'file_name': file.name,
        },
      );
      final reservation = reservationResponse.data!;
      reservationId = reservation['id'] as String;
      final upload = reservation['upload'] as Map<String, dynamic>;
      await _putDirectUpload(
        file,
        upload,
        contentLength: fileBytes,
        onSendProgress: onSendProgress,
      );
      final thumbnailUpload = reservation['thumbnail_upload'];
      if (thumbnail != null && thumbnailUpload is Map<String, dynamic>) {
        await _putDirectUpload(
          thumbnail,
          thumbnailUpload,
          contentLength: thumbnailBytes,
        );
      }
      uploadedToStorage = true;
      final completed = await _waitForCompletedUpload(reservationId);
      return SocialMediaAttachmentModel.fromJson(completed.data!);
    } catch (_) {
      // Do not race the server's verification/copy step with a cancellation if
      // the browser loses the response after the R2 upload already completed.
      // Abandoned reservations are removed by the normal cleanup job.
      if (reservationId != null && !uploadedToStorage) {
        try {
          await _dio.delete<void>(
            '/social/media/uploads/$reservationId',
            options: Options(
              connectTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 30),
            ),
          );
        } catch (_) {
          // The short-lived reservation expires and is cleaned up server-side.
        }
      }
      rethrow;
    }
  }

  Future<void> _putDirectUpload(
    XFile file,
    Map<String, dynamic> target, {
    required int contentLength,
    ProgressCallback? onSendProgress,
  }) async {
    if (target['protocol'] == 'tus') {
      await _putTusUpload(
        file,
        target,
        contentLength: contentLength,
        onSendProgress: onSendProgress,
      );
      return;
    }
    final rawHeaders = target['headers'] as Map<String, dynamic>? ?? const {};
    final headers = <String, dynamic>{
      for (final entry in rawHeaders.entries) entry.key: entry.value,
    };
    if (!kIsWeb) {
      headers[Headers.contentLengthHeader] = contentLength;
    }
    final data = kIsWeb ? await file.readAsBytes() : file.openRead();
    await _directUploadDio.put<void>(
      target['url'] as String,
      data: data,
      options: Options(
        headers: headers,
        followRedirects: false,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 300,
      ),
      onSendProgress: onSendProgress,
    );
  }

  Future<Response<Map<String, dynamic>>> _waitForCompletedUpload(
    String reservationId,
  ) async {
    for (var attempt = 0; attempt < 60; attempt += 1) {
      try {
        return await _dio.post<Map<String, dynamic>>(
          '/social/media/uploads/$reservationId/complete',
          options: Options(
            connectTimeout: const Duration(seconds: 30),
            sendTimeout: const Duration(minutes: 1),
            receiveTimeout: const Duration(minutes: 3),
          ),
        );
      } on DioException catch (error) {
        if (error.response?.statusCode != 425 || attempt == 59) rethrow;
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
    throw StateError('Video processing timed out. Try again in a moment.');
  }

  Future<void> _putTusUpload(
    XFile file,
    Map<String, dynamic> target, {
    required int contentLength,
    ProgressCallback? onSendProgress,
  }) async {
    final authHeaders = <String, dynamic>{
      for (final entry
          in (target['headers'] as Map<String, dynamic>? ?? const {}).entries)
        entry.key: entry.value,
    };
    final metadata = [
      'filename ${base64Encode(utf8.encode(file.name))}',
      'filetype ${base64Encode(utf8.encode(_mediaContentType(file, mediaType: 'video')))}',
    ].join(',');
    final created = await _directUploadDio.post<void>(
      target['url'] as String,
      options: Options(
        headers: {
          ...authHeaders,
          'Tus-Resumable': '1.0.0',
          'Upload-Length': contentLength,
          'Upload-Metadata': metadata,
        },
        validateStatus: (status) => status == 201,
      ),
    );
    final rawLocation = created.headers.value('location');
    if (rawLocation == null || rawLocation.isEmpty) {
      throw StateError('Video upload could not be started.');
    }
    final uploadUrl = Uri.parse(
      target['url'] as String,
    ).resolve(rawLocation).toString();
    const chunkSize = 5 * 1024 * 1024;
    final webBytes = kIsWeb ? await file.readAsBytes() : null;
    var offset = 0;
    var retries = 0;
    while (offset < contentLength) {
      final end = math.min(offset + chunkSize, contentLength);
      final chunkLength = end - offset;
      try {
        final data = kIsWeb
            ? webBytes!.sublist(offset, end)
            : file.openRead(offset, end);
        final response = await _directUploadDio.patch<void>(
          uploadUrl,
          data: data,
          options: Options(
            headers: {
              ...authHeaders,
              'Tus-Resumable': '1.0.0',
              'Upload-Offset': offset,
              'Content-Type': 'application/offset+octet-stream',
              Headers.contentLengthHeader: chunkLength,
            },
            validateStatus: (status) => status == 204,
          ),
          onSendProgress: (sent, _) {
            onSendProgress?.call(offset + sent, contentLength);
          },
        );
        offset =
            int.tryParse(response.headers.value('upload-offset') ?? '') ?? end;
        retries = 0;
      } on DioException {
        retries += 1;
        if (retries > 3) rethrow;
        final head = await _directUploadDio.head<void>(
          uploadUrl,
          options: Options(
            headers: {...authHeaders, 'Tus-Resumable': '1.0.0'},
            validateStatus: (status) => status == 200 || status == 204,
          ),
        );
        offset =
            int.tryParse(head.headers.value('upload-offset') ?? '') ?? offset;
      }
    }
  }

  bool _directUploadUnavailable(DioException error) {
    final status = error.response?.statusCode;
    return status == 404 || status == 409;
  }

  String _mediaContentType(XFile file, {required String mediaType}) {
    final provided = file.mimeType?.trim().toLowerCase();
    if (provided != null && provided.isNotEmpty) return provided;
    final name = file.name.toLowerCase();
    if (mediaType == 'video') {
      if (name.endsWith('.mov')) return 'video/quicktime';
      if (name.endsWith('.m4v')) return 'video/x-m4v';
      return 'video/mp4';
    }
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  Future<MultipartFile> _multipartFile(XFile file) async {
    if (kIsWeb) {
      return MultipartFile.fromBytes(
        await file.readAsBytes(),
        filename: file.name,
      );
    }
    return MultipartFile.fromFile(file.path, filename: file.name);
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

  Future<Map<String, dynamic>> fetchBillingConfig() async {
    final response = await _dio.get<Map<String, dynamic>>('/billing/config');
    return response.data ?? const {};
  }

  Future<Uri?> fetchSubscriptionManagementUrl() async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/billing/management',
    );
    final url = Uri.tryParse(response.data?['url'] as String? ?? '');
    return url?.scheme == 'https' && url!.host.isNotEmpty ? url : null;
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

String _friendlyDuration(Duration? duration) {
  if (duration == null || duration.isNegative) return 'a few minutes';
  final totalMinutes = duration.inMinutes <= 0 ? 1 : duration.inMinutes;
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours <= 0) return '${minutes}m';
  if (minutes <= 0) return '${hours}h';
  return '${hours}h ${minutes}m';
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
