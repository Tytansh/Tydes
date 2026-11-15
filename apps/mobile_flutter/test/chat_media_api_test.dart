import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/features/social/chat_media_api.dart';
import 'package:mobile_flutter/features/social/direct_message_api.dart';

class _Memory extends DemoPersistence {
  String? token = 'alice-token';
  @override
  Future<String?> loadAccessToken() async => token;
}

class _Call {
  _Call(this.options, this.bytes);
  final RequestOptions options;
  final Uint8List bytes;
}

class _Transport implements HttpClientAdapter {
  _Transport(this.handler);
  final FutureOr<ResponseBody> Function(_Call) handler;
  final calls = <_Call>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final builder = BytesBuilder();
    if (requestStream != null) {
      await for (final bytes in requestStream) {
        builder.add(bytes);
      }
    }
    final call = _Call(options, builder.takeBytes());
    calls.add(call);
    return handler(call);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody _empty(int status, [Map<String, List<String>>? headers]) =>
    ResponseBody.fromString('', status, headers: headers);

class _Fixture {
  _Fixture() {
    accountTransport = _Transport((call) {
      final request = call.options;
      if (request.path == '/users/me') {
        return _json({
          'id': request.headers['Authorization'] == 'Bearer bob-token'
              ? 'bob'
              : 'alice',
        });
      }
      if (request.path.endsWith('/capabilities')) {
        return _json({
          'enabled': true,
          'photos_enabled': true,
          'videos_enabled': true,
          'photo_max_bytes': 8 * 1024 * 1024,
          'video_max_bytes': 50 * 1024 * 1024,
        });
      }
      if (request.path == '/messages/media/uploads') {
        final type = (request.data as Map)['media_type'];
        return _json({
          'id': 'private-upload',
          'media_type': type,
          'upload': {
            'url': type == 'video'
                ? 'https://video.fixture.invalid/tusupload'
                : 'https://private-r2.fixture.invalid/chat/object?signed=temporary',
            'protocol': type == 'video' ? 'tus' : 'put',
            'headers': type == 'video'
                ? {'AuthorizationSignature': 'upload-only-signature'}
                : {'Content-Type': 'image/jpeg', 'If-None-Match': '*'},
          },
        });
      }
      if (request.path.endsWith('/complete')) {
        final response = _json(
          completeResponse ??
              {
                'id': 'private-upload',
                'media_type': completingType,
                'status': 'ready',
              },
        );
        if (!firstCompletion.isCompleted) firstCompletion.complete();
        return response;
      }
      if (request.path.endsWith('/access')) {
        return _json(
          accessResponse ??
              {
                'id': 'private-upload',
                'media_type': 'photo',
                'url': 'https://private-r2.fixture.invalid/object?signed=read',
                'expires_at': '2030-01-01T00:05:00Z',
              },
        );
      }
      if (request.method == 'DELETE') return _json({'canceled': true});
      return _json({'detail': 'Unknown fixture route'}, 404);
    });
    uploadTransport = _Transport(
      (call) => uploadHandler?.call(call) ?? _empty(204),
    );
    api = ChatMediaApi(
      DirectMessageApi(
        Dio(BaseOptions(baseUrl: 'https://api.fixture.invalid'))
          ..httpClientAdapter = accountTransport,
        memory,
      ),
      uploadDio: Dio(BaseOptions(followRedirects: false))
        ..httpClientAdapter = uploadTransport,
    );
  }

  final memory = _Memory();
  final firstCompletion = Completer<void>();
  late final _Transport accountTransport;
  late final _Transport uploadTransport;
  late final ChatMediaApi api;
  String completingType = 'photo';
  Map<String, dynamic>? completeResponse;
  Map<String, dynamic>? accessResponse;
  FutureOr<ResponseBody> Function(_Call)? uploadHandler;
  Future<ChatMediaSession> session([String type = 'direct']) =>
      api.session('alice', type, 'conversation-a');
}

XFile _photo([Uint8List? bytes]) => XFile.fromData(
  bytes ?? Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0]),
  name: 'photo.jpg',
  mimeType: 'image/jpeg',
);

void main() {
  test(
    'photo bytes go only to the signed provider PUT, never the API',
    () async {
      final fixture = _Fixture();
      final session = await fixture.session();
      final bytes = Uint8List.fromList(
        List.generate(257, (index) => index % 251),
      );
      final file = _photo(bytes);
      final reservations = <String>[];
      final result = await session.upload(
        file,
        'photo',
        cancellation: CancelToken(),
        onReservation: reservations.add,
        onProgress: (_) {},
      );
      expect(result.toJson(), {'id': 'private-upload', 'media_type': 'photo'});
      expect(reservations, ['private-upload']);
      final external = fixture.uploadTransport.calls.single;
      expect(external.options.method, 'PUT');
      expect(external.options.uri.host, 'private-r2.fixture.invalid');
      expect(external.options.headers['If-None-Match'], '*');
      expect(external.options.headers['Authorization'], isNull);
      expect(external.bytes, orderedEquals(bytes));
      final reserve = fixture.accountTransport.calls.singleWhere(
        (call) => call.options.path == '/messages/media/uploads',
      );
      expect(reserve.options.data, {
        'conversation_type': 'direct',
        'conversation_id': 'conversation-a',
        'media_type': 'photo',
        'content_type': 'image/jpeg',
        'size_bytes': bytes.length,
        'file_name': file.name,
      });
      for (final call in fixture.accountTransport.calls) {
        expect(call.options.uri.host, 'api.fixture.invalid');
        expect(call.options.headers['Authorization'], 'Bearer alice-token');
        expect(call.options.data, isNot(isA<FormData>()));
        expect(call.bytes.length, lessThan(1024));
      }
    },
  );

  test(
    'video chunks resume at the provider offset without exposing account auth',
    () async {
      final fixture = _Fixture()..completingType = 'video';
      final bytes = Uint8List.fromList(
        List.generate(5 * 1024 * 1024 + 17, (index) => index % 251),
      );
      const resumedOffset = 2 * 1024 * 1024;
      var patches = 0;
      fixture.uploadHandler = (call) {
        switch (call.options.method) {
          case 'POST':
            expect(call.options.headers['Upload-Length'], bytes.length);
            return _empty(201, {
              'location': ['/tusupload/resource-a'],
            });
          case 'PATCH':
            patches++;
            if (patches == 1) {
              expect(call.options.headers['Upload-Offset'], 0);
              expect(
                call.bytes,
                orderedEquals(bytes.sublist(0, 5 * 1024 * 1024)),
              );
              return _json({'detail': 'Simulated interrupted chunk'}, 503);
            }
            expect(call.options.headers['Upload-Offset'], resumedOffset);
            expect(call.bytes, orderedEquals(bytes.sublist(resumedOffset)));
            return _empty(204, {
              'upload-offset': ['${bytes.length}'],
            });
          case 'HEAD':
            return _empty(200, {
              'upload-offset': ['$resumedOffset'],
            });
          default:
            throw StateError('Unexpected upload method');
        }
      };
      final result = await (await fixture.session()).upload(
        XFile.fromData(bytes, name: 'clip.mp4', mimeType: 'video/mp4'),
        'video',
        cancellation: CancelToken(),
        onReservation: (_) {},
        onProgress: (_) {},
      );
      expect(result.mediaType, 'video');
      expect(fixture.uploadTransport.calls.map((call) => call.options.method), [
        'POST',
        'PATCH',
        'HEAD',
        'PATCH',
      ]);
      for (final call in fixture.uploadTransport.calls) {
        expect(call.options.uri.origin, 'https://video.fixture.invalid');
        expect(call.options.headers['Authorization'], isNull);
        expect(
          call.options.headers['AuthorizationSignature'],
          'upload-only-signature',
        );
      }
    },
  );

  test(
    'TUS rejects a cross-origin resume location before sending bytes',
    () async {
      final fixture = _Fixture()..completingType = 'video';
      fixture.uploadHandler = (_) => _empty(201, {
        'location': ['https://unrelated.fixture.invalid/steal-upload'],
      });
      final session = await fixture.session();
      await expectLater(
        session.upload(
          XFile.fromData(Uint8List(12), name: 'clip.mp4'),
          'video',
          cancellation: CancelToken(),
          onReservation: (_) {},
          onProgress: (_) {},
        ),
        throwsStateError,
      );
      expect(fixture.uploadTransport.calls.single.options.method, 'POST');
      expect(fixture.uploadTransport.calls.single.bytes, isEmpty);
      expect(
        fixture.accountTransport.calls.any(
          (call) => call.options.path.endsWith('/complete'),
        ),
        isFalse,
      );
    },
  );

  for (final offset in <String?>[null, 'invalid', '0', '1', '13']) {
    test('TUS rejects missing or inexact PATCH offset ACK $offset', () async {
      final fixture = _Fixture()..completingType = 'video';
      fixture.uploadHandler = (call) => call.options.method == 'POST'
          ? _empty(201, {
              'location': ['/tusupload/resource-a'],
            })
          : _empty(204, {
              if (offset != null) 'upload-offset': [offset],
            });
      final session = await fixture.session();
      await expectLater(
        session.upload(
          XFile.fromData(Uint8List(12), name: 'clip.mp4'),
          'video',
          cancellation: CancelToken(),
          onReservation: (_) {},
          onProgress: (_) {},
        ),
        throwsStateError,
      );
      expect(fixture.uploadTransport.calls.map((call) => call.options.method), [
        'POST',
        'PATCH',
      ]);
      expect(
        fixture.accountTransport.calls.any(
          (call) => call.options.path.endsWith('/complete'),
        ),
        isFalse,
      );
    });
  }

  test('TUS stops after three failed chunk recoveries', () async {
    final fixture = _Fixture()..completingType = 'video';
    fixture.uploadHandler = (call) => switch (call.options.method) {
      'POST' => _empty(201, {
        'location': ['/tusupload/resource-a'],
      }),
      'HEAD' => _empty(200, {
        'upload-offset': ['0'],
      }),
      _ => _json({'detail': 'Simulated disconnected upload'}, 503),
    };
    await expectLater(
      (await fixture.session()).upload(
        XFile.fromData(Uint8List(12), name: 'clip.mp4'),
        'video',
        cancellation: CancelToken(),
        onReservation: (_) {},
        onProgress: (_) {},
      ),
      throwsA(isA<DioException>()),
    );
    expect(
      fixture.uploadTransport.calls.where(
        (call) => call.options.method == 'PATCH',
      ),
      hasLength(4),
    );
    expect(
      fixture.uploadTransport.calls.where(
        (call) => call.options.method == 'HEAD',
      ),
      hasLength(3),
    );
    expect(
      fixture.accountTransport.calls.any(
        (call) => call.options.path.endsWith('/complete'),
      ),
      isFalse,
    );
  });

  test(
    'processing polls to ready and validates every completion ACK',
    () async {
      final fixture = _Fixture();
      final session = await fixture.session();
      fixture.completeResponse = {
        'id': 'private-upload',
        'media_type': 'video',
        'status': 'processing',
      };
      final result = session.complete('private-upload', 'video', CancelToken());
      await fixture.firstCompletion.future;
      expect(
        fixture.accountTransport.calls.where(
          (call) => call.options.path.endsWith('/complete'),
        ),
        hasLength(1),
      );
      fixture.completeResponse = {
        'id': 'private-upload',
        'media_type': 'video',
        'status': 'ready',
      };
      expect((await result).mediaType, 'video');
      expect(
        fixture.accountTransport.calls.where(
          (call) => call.options.path.endsWith('/complete'),
        ),
        hasLength(2),
      );
    },
  );

  for (final ack in [
    {'id': 'another-upload', 'media_type': 'photo', 'status': 'ready'},
    {'id': 'private-upload', 'media_type': 'video', 'status': 'ready'},
    {'id': 'private-upload', 'media_type': 'photo', 'status': 'failed'},
  ]) {
    test('completion rejects unconfirmed ACK $ack', () async {
      final fixture = _Fixture()..completeResponse = ack;
      final session = await fixture.session();
      await expectLater(
        session.complete('private-upload', 'photo', CancelToken()),
        throwsStateError,
      );
    });
  }

  test(
    'cancel targets only the authenticated upload cancellation endpoint',
    () async {
      final fixture = _Fixture();
      await (await fixture.session('event')).cancel('private-upload');
      final call = fixture.accountTransport.calls.last.options;
      expect(call.method, 'DELETE');
      expect(call.path, '/messages/media/uploads/private-upload');
      expect(call.headers['Authorization'], 'Bearer alice-token');
      expect(fixture.uploadTransport.calls, isEmpty);
    },
  );

  test('pre-canceled completion makes no request', () async {
    final fixture = _Fixture();
    final session = await fixture.session();
    final token = CancelToken()..cancel('User canceled');
    await expectLater(
      session.complete('private-upload', 'photo', token),
      throwsA(
        isA<DioException>().having(CancelToken.isCancel, 'canceled', isTrue),
      ),
    );
    expect(fixture.accountTransport.calls, hasLength(1));
  });

  test(
    'switching accounts before access or upload sends no old-account request',
    () async {
      final fixture = _Fixture();
      final session = await fixture.session();
      fixture.memory.token = 'bob-token';
      await expectLater(session.access('private-upload'), throwsStateError);
      await expectLater(
        session.upload(
          _photo(),
          'photo',
          cancellation: CancelToken(),
          onReservation: (_) {},
          onProgress: (_) {},
        ),
        throwsStateError,
      );
      expect(fixture.accountTransport.calls, hasLength(1));
      expect(fixture.uploadTransport.calls, isEmpty);
    },
  );

  test(
    'session verification coalesces only for the same owner and token',
    () async {
      final fixture = _Fixture();
      await Future.wait([
        fixture.api.session('alice', 'direct', 'first-room'),
        fixture.api.session('alice', 'event', 'second-room'),
      ]);
      expect(
        fixture.accountTransport.calls.where(
          (call) => call.options.path == '/users/me',
        ),
        hasLength(1),
      );
      await expectLater(
        fixture.api.session('bob', 'direct', 'third-room'),
        throwsStateError,
      );
      fixture.memory.token = 'bob-token';
      final bob = await fixture.api.session('bob', 'direct', 'third-room');
      expect(bob.account.ownerId, 'bob');
      expect(
        fixture.accountTransport.calls.last.options.headers['Authorization'],
        'Bearer bob-token',
      );
      await expectLater(
        fixture.api.session('alice', 'direct', 'first-room'),
        throwsStateError,
      );
    },
  );

  test(
    'account switch during PUT cannot confirm the old upload or use new auth',
    () async {
      final fixture = _Fixture();
      fixture.uploadHandler = (_) {
        fixture.memory.token = 'bob-token';
        return _empty(204);
      };
      final session = await fixture.session();
      await expectLater(
        session.upload(
          _photo(),
          'photo',
          cancellation: CancelToken(),
          onReservation: (_) {},
          onProgress: (_) {},
        ),
        throwsStateError,
      );
      expect(fixture.uploadTransport.calls, hasLength(1));
      expect(
        fixture.uploadTransport.calls.single.options.headers['Authorization'],
        isNull,
      );
      expect(
        fixture.accountTransport.calls.any(
          (call) => call.options.path.endsWith('/complete'),
        ),
        isFalse,
      );
      expect(
        fixture.accountTransport.calls.every(
          (call) =>
              call.options.headers['Authorization'] == 'Bearer alice-token',
        ),
        isTrue,
      );
    },
  );

  test(
    'access is conversation-scoped and rejects wrong ID or insecure URL',
    () async {
      final fixture = _Fixture();
      final session = await fixture.session('event');
      expect((await session.access('private-upload'))['media_type'], 'photo');
      expect(fixture.accountTransport.calls.last.options.data, {
        'conversation_type': 'event',
        'conversation_id': 'conversation-a',
      });
      for (final bad in [
        {
          'id': 'other-upload',
          'url': 'https://private-r2.fixture.invalid/object',
        },
        {
          'id': 'private-upload',
          'url': 'http://insecure.fixture.invalid/object',
        },
      ]) {
        fixture.accessResponse = bad;
        await expectLater(session.access('private-upload'), throwsStateError);
      }
    },
  );
}
