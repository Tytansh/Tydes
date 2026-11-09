import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';

class MemorySessions extends DemoPersistence {
  String? token = 'old-test-session';
  @override
  Future<String?> loadAccessToken() async => token;
  @override
  Future<void> saveAccessToken(String value) async {
    token = value;
  }

  @override
  Future<void> clearAccessToken() async {
    token = null;
  }

  @override
  Future<bool> clearAccessTokenIfMatches(String expected) async {
    if (token != expected) return false;
    token = null;
    return true;
  }

  @override
  Future<void> saveFavoriteSpotIds(List<String> ids) async {}
  @override
  Future<List<String>> loadFavoriteSpotIds() async => [];
}

Map<String, dynamic> profileJson(String id) => {
  'id': id,
  'email': '$id@example.com',
  'display_name': id,
  'handle': id,
  'bio': '',
  'surf_skill': 'intermediate',
  'home_region': '',
  'locale': 'en',
  'email_verified': true,
};

ResponseBody body(Object data, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

class FakeTransport implements HttpClientAdapter {
  FakeTransport(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => respond(options);
  @override
  void close({bool force = false}) {}
}

void main() {
  test('failed email login does not erase an existing session', () async {
    final sessions = MemorySessions();
    final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
      ..httpClientAdapter = FakeTransport((_) async => body({}, 400));
    await expectLater(SurfRepository(dio, sessions).login('test@example.com',
      'en', password: 'incorrect-test-password'), throwsStateError);
    expect(sessions.token, 'old-test-session');
  });
  for (final oldStatus in [200, 401, 403]) {
    test(
      'late old-session $oldStatus cannot overwrite or clear a new login',
      () async {
        final sessions = MemorySessions();
        final started = Completer<void>();
        final old = Completer<ResponseBody>();
        final seen = <String?>[];
        final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
          ..httpClientAdapter = FakeTransport((options) async {
            final auth = options.headers['Authorization'] as String?;
            seen.add(auth);
            if (auth == 'Bearer old-test-session') {
              started.complete();
              return old.future;
            }
            return body(profileJson('newaccount'));
          });
        final repo = SurfRepository(dio, sessions);
        final profile = repo.fetchMe();
        await started.future;
        await sessions.saveAccessToken('new-test-session');
        old.complete(body(profileJson('oldaccount'), oldStatus));
        expect((await profile).id, 'newaccount');
        expect(sessions.token, 'new-test-session');
        expect(DemoSeed.me.id, 'newaccount');
        expect(seen, ['Bearer old-test-session', 'Bearer new-test-session']);
      },
    );
  }

  test('a current-session rejection still signs out', () async {
    final sessions = MemorySessions();
    final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
      ..httpClientAdapter = FakeTransport((_) async => body({}, 401));
    await expectLater(
      SurfRepository(dio, sessions).fetchMe(),
      throwsStateError,
    );
    expect(sessions.token, isNull);
  });

  test('a late logout does not clear a newer login', () async {
    final sessions = MemorySessions();
    final started = Completer<void>();
    final pending = Completer<ResponseBody>();
    final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
      ..httpClientAdapter = FakeTransport((options) {
        expect(options.headers['Authorization'], 'Bearer old-test-session');
        started.complete();
        return pending.future;
      });
    final logout = SurfRepository(dio, sessions).logout();
    await started.future;
    await sessions.saveAccessToken('new-test-session');
    pending.complete(body(profileJson('signedout')));
    await logout;
    expect(sessions.token, 'new-test-session');
  });

  test('deletion failure is visible and keeps the session for retry', () async {
    final sessions = MemorySessions();
    final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
      ..httpClientAdapter = FakeTransport((_) async => body({}, 503));
    await expectLater(
      SurfRepository(dio, sessions).deleteAccount(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('could not be confirmed'),
        ),
      ),
    );
    expect(sessions.token, 'old-test-session');
  });

  test('confirmed deletion clears only its own session', () async {
    final sessions = MemorySessions();
    final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
      ..httpClientAdapter = FakeTransport(
        (_) async => body(profileJson('signedout')),
      );
    await SurfRepository(dio, sessions).deleteAccount();
    expect(sessions.token, isNull);
  });

  test('Google sign in and sign up send explicit creation intent', () async {
    final sessions = MemorySessions();
    final intent = <bool>[];
    final dio = Dio(BaseOptions(baseUrl: 'https://test.invalid'))
      ..httpClientAdapter = FakeTransport((options) async {
        intent.add((options.data as Map)['allow_signup'] as bool);
        return body({
          'session': {
            'user': profileJson('googleuser'),
            'access_token': 'google-test-session',
          },
        });
      });
    final repo = SurfRepository(dio, sessions);
    for (final signup in [false, true]) {
      await repo.loginWithGoogle(
        credential: 'synthetic-test-credential',
        challengeId: 'test-challenge',
        verifier: 'test-verifier',
        locale: 'en',
        allowSignup: signup,
      );
    }
    expect(intent, [false, true]);
  });
}
