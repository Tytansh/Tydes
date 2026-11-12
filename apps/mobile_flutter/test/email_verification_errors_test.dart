import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_error_message.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';

import 'auth_session_test.dart'
    show MemorySessions, FakeTransport, body, profileJson;

const _blocked = {
  'detail': {
    'code': 'email_verification_required',
    'message': 'Verify your email to continue.',
  },
};

class _FavoriteWrites extends MemorySessions {
  int writes = 0;
  @override
  Future<void> saveFavoriteSpotIds(List<String> ids) async => writes++;
}

void main() {
  test(
    'verification 403 preserves the session and never uses a demo profile',
    () async {
      final sessions = MemorySessions();
      final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
        ..httpClientAdapter = FakeTransport((_) async => body(_blocked, 403));
      await expectLater(
        SurfRepository(dio, sessions).fetchMe(),
        throwsA(predicate(isEmailVerificationRequired)),
      );
      expect(sessions.token, 'old-test-session');
    },
  );

  test(
    'a latched verification requirement rejects a cached verified identity',
    () async {
      final sessions = MemorySessions();
      var blocked = false;
      var offline = false;
      final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
        ..httpClientAdapter = FakeTransport(
          (_) async => offline ? body({}, 503) : body(profileJson('owner')),
        );
      final repo = SurfRepository(
        dio,
        sessions,
        isVerificationRequired: (_) => blocked,
      );
      expect((await repo.fetchMe()).emailVerified, isTrue);
      blocked = true;
      offline = true;
      await expectLater(
        repo.fetchMe(),
        throwsA(isA<EmailVerificationRequiredException>()),
      );
      expect(sessions.token, 'old-test-session');
    },
  );

  test('blocked private reads never turn into seeded success', () async {
    final sessions = MemorySessions();
    final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
      ..httpClientAdapter = FakeTransport((_) async => body(_blocked, 403));
    final repo = SurfRepository(dio, sessions);
    final requests = <Future<Object?> Function()>[
      repo.fetchDashboard,
      repo.fetchSpots,
      repo.fetchTrips,
      repo.fetchFriends,
      repo.fetchSocialPosts,
      repo.fetchPlans,
      repo.fetchAds,
      () => repo.fetchForecasts(spotId: 'test-spot'),
      () => repo.fetchTides('test-spot'),
      () => repo.fetchSurfWindow('test-spot'),
      repo.fetchSocialEngagement,
    ];
    for (final request in requests) {
      await expectLater(
        request(),
        throwsA(predicate(isEmailVerificationRequired)),
      );
    }
    expect(sessions.token, 'old-test-session');
  });

  test(
    'blocked favorite changes never report local success or persist data',
    () async {
      final original = DemoSeed.me;
      addTearDown(() => DemoSeed.me = original);
      DemoSeed.me = original.copyWith(favoriteSpotIds: ['saved-before']);
      final sessions = _FavoriteWrites();
      final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
        ..httpClientAdapter = FakeTransport((_) async => body(_blocked, 403));
      final repo = SurfRepository(dio, sessions);
      await expectLater(
        repo.addFavoriteSpot('new-spot'),
        throwsA(predicate(isEmailVerificationRequired)),
      );
      await expectLater(
        repo.removeFavoriteSpot('saved-before'),
        throwsA(predicate(isEmailVerificationRequired)),
      );
      expect(DemoSeed.me.favoriteSpotIds, ['saved-before']);
      expect(sessions.writes, 0);
      final container = ProviderContainer(
        overrides: [surfRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(favoriteSpotIdsProvider.notifier).toggle('new-spot'),
        throwsA(predicate(isEmailVerificationRequired)),
      );
      expect(container.read(favoriteSpotIdsProvider), {'saved-before'});
    },
  );

  test(
    'current-token verification errors latch once; confirmed me clears it',
    () async {
      final sessions = MemorySessions();
      final container = ProviderContainer(
        overrides: [demoPersistenceProvider.overrideWithValue(sessions)],
      );
      addTearDown(container.dispose);
      final dio = container.read(dioProvider)
        ..httpClientAdapter = FakeTransport(
          (request) async => request.path == '/users/me'
              ? body(profileJson('owner'))
              : body(_blocked, 403),
        );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          dio.get('/social/posts'),
          throwsA(isA<DioException>()),
        );
      }
      expect(
        container.read(emailVerificationRequiredTokenProvider),
        'old-test-session',
      );
      expect(container.read(accountVerificationRefreshKeyProvider), 1);
      await dio.get('/users/me');
      expect(container.read(emailVerificationRequiredTokenProvider), isNull);
    },
  );

  test(
    'late old-token 403 cannot gate a different signed-in account',
    () async {
      final sessions = MemorySessions();
      final started = Completer<void>();
      final response = Completer<ResponseBody>();
      final container = ProviderContainer(
        overrides: [demoPersistenceProvider.overrideWithValue(sessions)],
      );
      addTearDown(container.dispose);
      final dio = container.read(dioProvider)
        ..httpClientAdapter = FakeTransport((_) {
          started.complete();
          return response.future;
        });
      final request = dio.get('/social/posts');
      final assertion = expectLater(request, throwsA(isA<DioException>()));
      await started.future;
      sessions.token = 'new-test-session';
      response.complete(body(_blocked, 403));
      await assertion;
      expect(container.read(emailVerificationRequiredTokenProvider), isNull);
      expect(container.read(accountVerificationRefreshKeyProvider), 0);
      expect(sessions.token, 'new-test-session');
    },
  );

  test('new-session request clears a stale verification latch', () async {
    final sessions = MemorySessions()..token = 'new-test-session';
    final container = ProviderContainer(
      overrides: [demoPersistenceProvider.overrideWithValue(sessions)],
    );
    addTearDown(container.dispose);
    container.read(emailVerificationRequiredTokenProvider.notifier).state =
        'old-test-session';
    final dio = container.read(
      dioProvider,
    )..httpClientAdapter = FakeTransport((_) async => body(profileJson('new')));
    await dio.get('/users/me');
    expect(container.read(emailVerificationRequiredTokenProvider), isNull);
  });

  test('verification errors explain verification, not a sign-in loop', () {
    final error = DioException(
      requestOptions: RequestOptions(path: '/spots'),
      response: Response(
        requestOptions: RequestOptions(path: '/spots'),
        statusCode: 403,
        data: _blocked,
      ),
    );
    expect(friendlyErrorMessage(error), 'Verify your email to continue.');
  });
}
