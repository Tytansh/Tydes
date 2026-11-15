import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/direct_message_api.dart';
import 'package:mobile_flutter/features/social/event_chat_controls.dart';

import 'auth_session_test.dart' show MemorySessions, FakeTransport, body;

Map<String, dynamic> _settings({bool muted = false, bool left = false}) => {
  'user_id': 'alice',
  'post_id': 'surf-event',
  'muted': muted,
  'left': left,
};

class _Fixture {
  _Fixture() {
    final api = DirectMessageApi(
      Dio(BaseOptions(baseUrl: 'https://event-controls.fixture.invalid'))
        ..httpClientAdapter = FakeTransport((request) async {
          expect(request.headers['Authorization'], 'Bearer old-test-session');
          calls.add(request);
          if (request.path == '/users/me') return body({'id': 'alice'});
          final custom = handler;
          if (custom != null) return custom(request);
          if (request.method == 'PATCH') {
            settings = {...settings, 'muted': (request.data as Map)['muted']};
          } else if (request.path.endsWith('/leave')) {
            settings = {...settings, 'left': true};
          } else if (request.path.endsWith('/join')) {
            settings = {...settings, 'left': false};
          }
          return body(settings);
        }),
      memory,
    );
    controller = EventChatControlsController(
      api: api,
      ownerId: 'alice',
      onConfirmedChange: () => confirmedChanges++,
    );
  }
  final memory = MemorySessions();
  final calls = <RequestOptions>[];
  var settings = _settings();
  int confirmedChanges = 0;
  late final EventChatControlsController controller;
  Future<ResponseBody> Function(RequestOptions)? handler;
  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.dispose();
  }
}

void main() {
  test(
    'fetch stores only owner/post-confirmed settings without mutation notification',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      var notifications = 0;
      fixture.controller.addListener(
        (_) => notifications++,
        fireImmediately: false,
      );
      final first = await fixture.controller.fetch('surf-event');
      expect(first.muted, isFalse);
      expect(first.left, isFalse);
      await fixture.controller.fetch('surf-event');
      expect(notifications, 1);
      expect(fixture.confirmedChanges, 0);
    },
  );

  test(
    'pending mute does not mutate snapshot and prevents duplicate controls',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.controller.fetch('surf-event');
      final started = Completer<void>();
      final ack = Completer<ResponseBody>();
      fixture.handler = (_) {
        started.complete();
        return ack.future;
      };
      final change = fixture.controller.setMuted('surf-event', true);
      expect(fixture.controller.state.pending, contains('surf-event'));
      await started.future;
      expect(fixture.controller.current('surf-event')!.muted, isFalse);
      await expectLater(
        fixture.controller.leave('surf-event'),
        throwsStateError,
      );
      ack.complete(body(_settings(muted: true)));
      await change;
      expect(fixture.controller.current('surf-event')!.muted, isTrue);
      expect(fixture.controller.state.pending, isEmpty);
      expect(fixture.confirmedChanges, 1);
    },
  );

  test(
    'leave and rejoin confirm chat preference only, never change RSVP',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.controller.leave('surf-event');
      expect(fixture.controller.current('surf-event')!.left, isTrue);
      await fixture.controller.join('surf-event');
      expect(fixture.controller.current('surf-event')!.left, isFalse);
      expect(fixture.confirmedChanges, 2);
      expect(
        fixture.calls
            .where((call) => call.path != '/users/me')
            .map((call) => call.path),
        [
          '/social/posts/surf-event/chat/leave',
          '/social/posts/surf-event/chat/join',
        ],
      );
      expect(
        fixture.calls.where((call) => call.path.contains('rsvp')),
        isEmpty,
      );
    },
  );

  for (final bad in [
    {..._settings(muted: true), 'user_id': 'bob'},
    {..._settings(muted: true), 'post_id': 'another-event'},
    _settings(muted: false),
    {..._settings(muted: true), 'left': 'false'},
  ]) {
    test('invalid mutation ACK retains previous settings $bad', () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.controller.fetch('surf-event');
      fixture.handler = (_) async => body(bad);
      await expectLater(
        fixture.controller.setMuted('surf-event', true),
        throwsStateError,
      );
      expect(fixture.controller.current('surf-event')!.muted, isFalse);
      expect(fixture.controller.state.pending, isEmpty);
      expect(fixture.confirmedChanges, 0);
    });
  }

  test(
    'backend failure retains confirmed settings and releases pending action',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.controller.fetch('surf-event');
      fixture.handler = (_) async => body({'detail': 'Unavailable'}, 503);
      await expectLater(
        fixture.controller.leave('surf-event'),
        throwsA(isA<DioException>()),
      );
      expect(fixture.controller.current('surf-event')!.left, isFalse);
      expect(fixture.controller.state.pending, isEmpty);
      expect(fixture.confirmedChanges, 0);
    },
  );

  test(
    'old delayed settings GET cannot overwrite confirmed newer mute',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final started = Completer<void>();
      final oldGet = Completer<ResponseBody>();
      fixture.handler = (request) async {
        if (request.method == 'GET') {
          started.complete();
          return oldGet.future;
        }
        return body(_settings(muted: true));
      };
      final loading = fixture.controller.fetch('surf-event');
      await started.future;
      await fixture.controller.setMuted('surf-event', true);
      oldGet.complete(body(_settings()));
      expect((await loading).muted, isTrue);
      expect(fixture.controller.current('surf-event')!.muted, isTrue);
      expect(fixture.confirmedChanges, 1);
    },
  );

  for (final invalidate in ['token', 'dispose']) {
    test('$invalidate change discards delayed control ACK', () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.controller.fetch('surf-event');
      final started = Completer<void>();
      final ack = Completer<ResponseBody>();
      fixture.handler = (_) {
        started.complete();
        return ack.future;
      };
      final change = fixture.controller.leave('surf-event');
      final rejected = expectLater(change, throwsStateError);
      await started.future;
      if (invalidate == 'token') {
        fixture.memory.token = 'other-account-token';
      } else {
        fixture.dispose();
      }
      ack.complete(body(_settings(left: true)));
      await rejected;
      expect(fixture.confirmedChanges, 0);
      if (invalidate == 'token') {
        expect(fixture.controller.current('surf-event')!.left, isFalse);
        expect(fixture.controller.state.pending, isEmpty);
      }
    });
  }
}
