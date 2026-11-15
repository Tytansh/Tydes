import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/direct_message_api.dart';

import 'auth_session_test.dart' show MemorySessions, FakeTransport, body;

class _Fixture {
  _Fixture() {
    api = DirectMessageApi(
      Dio(BaseOptions(baseUrl: 'https://controls.fixture.invalid'))
        ..httpClientAdapter = FakeTransport((request) async {
          calls.add(request);
          expect(request.headers['Authorization'], 'Bearer old-test-session');
          if (request.path == '/users/me') return body({'id': 'alice'});
          if (beforeAck != null) await beforeAck!();
          if (status != 200) {
            return body({'detail': 'Simulated outage'}, status);
          }
          if (request.method == 'PATCH') {
            return body(
              settingsAck ??
                  {
                    'user_id': 'alice',
                    'id': 'dm-alice-bob',
                    'muted': (request.data as Map)['muted'],
                    'messages': <Map<String, dynamic>>[],
                  },
            );
          }
          if (request.method == 'DELETE') {
            return body(
              deleteAck ??
                  {
                    'user_id': 'alice',
                    'thread_id': 'dm-alice-bob',
                    'deleted': true,
                  },
            );
          }
          return body({'detail': 'Unknown test route'}, 404);
        }),
      memory,
    );
  }

  final memory = MemorySessions();
  final calls = <RequestOptions>[];
  late final DirectMessageApi api;
  Map<String, dynamic>? settingsAck;
  Map<String, dynamic>? deleteAck;
  FutureOr<void> Function()? beforeAck;
  int status = 200;

  Future<DirectMessageSession> session() => api.openSession('alice');
}

void main() {
  for (final muted in [true, false]) {
    test(
      'mute=$muted uses authenticated PATCH and awaits confirmed full thread',
      () async {
        final fixture = _Fixture();
        final session = await fixture.session();
        await session.setMuted('dm-alice-bob', muted);
        final request = fixture.calls.last;
        expect(request.method, 'PATCH');
        expect(request.path, '/messages/threads/dm-alice-bob/settings');
        expect(request.data, {'muted': muted});
        expect(fixture.calls, hasLength(2));
      },
    );
  }

  test(
    'delete uses requester-authenticated DELETE only after confirmed ACK',
    () async {
      final fixture = _Fixture();
      await (await fixture.session()).deleteThread('dm-alice-bob');
      final request = fixture.calls.last;
      expect(request.method, 'DELETE');
      expect(request.path, '/messages/threads/dm-alice-bob');
      expect(request.data, isNull);
      expect(fixture.calls, hasLength(2));
    },
  );

  final validSettings = <String, dynamic>{
    'user_id': 'alice',
    'id': 'dm-alice-bob',
    'muted': true,
    'messages': <Map<String, dynamic>>[],
  };
  for (final bad in <Map<String, dynamic>>[
    {...validSettings, 'user_id': 'bob'},
    {...validSettings}..remove('user_id'),
    {...validSettings, 'id': 'another-room'},
    {...validSettings, 'muted': false},
    {...validSettings, 'muted': 'true'},
    {...validSettings, 'messages': <String, dynamic>{}},
    {...validSettings}..remove('messages'),
  ]) {
    test(
      'mute rejects unconfirmed owner/thread/value/full-history ACK $bad',
      () async {
        final fixture = _Fixture()..settingsAck = bad;
        await expectLater(
          (await fixture.session()).setMuted('dm-alice-bob', true),
          throwsStateError,
        );
      },
    );
  }

  final validDelete = <String, dynamic>{
    'user_id': 'alice',
    'thread_id': 'dm-alice-bob',
    'deleted': true,
  };
  for (final bad in <Map<String, dynamic>>[
    {...validDelete, 'user_id': 'bob'},
    {...validDelete}..remove('user_id'),
    {...validDelete, 'thread_id': 'another-room'},
    {...validDelete, 'deleted': false},
    {...validDelete, 'deleted': 'true'},
  ]) {
    test('delete rejects unconfirmed owner/thread/deleted ACK $bad', () async {
      final fixture = _Fixture()..deleteAck = bad;
      await expectLater(
        (await fixture.session()).deleteThread('dm-alice-bob'),
        throwsStateError,
      );
    });
  }

  for (final action in ['mute', 'delete']) {
    test(
      '$action propagates backend failure instead of faking success',
      () async {
        final fixture = _Fixture()..status = 503;
        final session = await fixture.session();
        await expectLater(
          action == 'mute'
              ? session.setMuted('dm-alice-bob', true)
              : session.deleteThread('dm-alice-bob'),
          throwsA(isA<DioException>()),
        );
      },
    );

    test('$action sends nothing after account token changes', () async {
      final fixture = _Fixture();
      final session = await fixture.session();
      fixture.memory.token = 'another-account-token';
      await expectLater(
        action == 'mute'
            ? session.setMuted('dm-alice-bob', true)
            : session.deleteThread('dm-alice-bob'),
        throwsStateError,
      );
      expect(fixture.calls, hasLength(1));
    });

    test(
      '$action discards valid-looking delayed ACK after account switch',
      () async {
        final fixture = _Fixture();
        final session = await fixture.session();
        final started = Completer<void>();
        final complete = Completer<void>();
        fixture.beforeAck = () async {
          started.complete();
          await complete.future;
        };
        final result = action == 'mute'
            ? session.setMuted('dm-alice-bob', true)
            : session.deleteThread('dm-alice-bob');
        final rejected = expectLater(result, throwsStateError);
        await started.future;
        fixture.memory.token = 'another-account-token';
        complete.complete();
        await rejected;
        expect(fixture.calls, hasLength(2));
      },
    );
  }
}
