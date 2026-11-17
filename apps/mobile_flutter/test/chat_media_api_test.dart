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
        final data = request.data as Map;
        final type = data['media_type'];
        return _json({
          'id': 'private-upload',
          'media_type': type,
          'upload': {
            'url':
                'https://private-r2.fixture.invalid/chat/object?signed=temporary',
            'protocol': uploadProtocol,
            'headers': {
              'Content-Type': data['content_type'],
              'If-None-Match': '*',
            },
          },
        });
      }
      if (request.path.endsWith('/complete')) {
        if (completionHandler != null) return completionHandler!(call);
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
        Dio(
          BaseOptions(
            baseUrl: 'https://api.fixture.invalid',
            receiveTimeout: const Duration(seconds: 18),
          ),
        )..httpClientAdapter = accountTransport,
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
  String uploadProtocol = 'put';
  Map<String, dynamic>? completeResponse;
  Map<String, dynamic>? accessResponse;
  FutureOr<ResponseBody> Function(_Call)? completionHandler;
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
      // Dio serializes browser binary-body lengths as decimal header strings.
      expect(
        external.options.headers['Content-Length'].toString(),
        bytes.length.toString(),
      );
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

  test('video bytes use one signed private R2 PUT before validation', () async {
    final fixture = _Fixture()..completingType = 'video';
    final bytes = Uint8List.fromList(
      List.generate(5 * 1024 * 1024 + 17, (index) => index % 251),
    );
    final result = await (await fixture.session()).upload(
      XFile.fromData(bytes, name: 'clip.mp4', mimeType: 'video/mp4'),
      'video',
      cancellation: CancelToken(),
      onReservation: (_) {},
      onProgress: (_) {},
    );
    expect(result.mediaType, 'video');
    final external = fixture.uploadTransport.calls.single;
    expect(external.options.method, 'PUT');
    expect(external.options.uri.host, 'private-r2.fixture.invalid');
    expect(external.options.headers['Content-Type'], 'video/mp4');
    expect(external.options.headers['If-None-Match'], '*');
    expect(
      external.options.headers['Content-Length'].toString(),
      bytes.length.toString(),
    );
    expect(external.options.headers['Authorization'], isNull);
    expect(external.options.headers['AuthorizationSignature'], isNull);
    expect(external.options.headers['Tus-Resumable'], isNull);
    expect(external.options.headers['Upload-Metadata'], isNull);
    expect(external.bytes, orderedEquals(bytes));
    expect(
      fixture.accountTransport.calls.last.options.path,
      '/messages/media/uploads/private-upload/complete',
    );
    expect(
      fixture.accountTransport.calls.every(
        (call) => call.bytes.length < 1024 && call.options.data is! FormData,
      ),
      isTrue,
    );
  });

  for (final protocol in ['tus', 'post', 'PUT', '']) {
    test(
      'unsupported private protocol $protocol sends no provider request',
      () async {
        final fixture = _Fixture()
          ..completingType = 'video'
          ..uploadProtocol = protocol;
        await expectLater(
          (await fixture.session()).upload(
            XFile.fromData(Uint8List(12), name: 'clip.mp4'),
            'video',
            cancellation: CancelToken(),
            onReservation: (_) {},
            onProgress: (_) {},
          ),
          throwsStateError,
        );
        expect(fixture.uploadTransport.calls, isEmpty);
        expect(
          fixture.accountTransport.calls.any(
            (call) => call.options.path.endsWith('/complete'),
          ),
          isFalse,
        );
      },
    );
  }

  test(
    'failed video PUT never confirms an upload or retries blindly',
    () async {
      final fixture = _Fixture()..completingType = 'video';
      fixture.uploadHandler = (_) => _json({'detail': 'Unavailable'}, 503);
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
      expect(fixture.uploadTransport.calls, hasLength(1));
      expect(
        fixture.accountTransport.calls.any(
          (call) => call.options.path.endsWith('/complete'),
        ),
        isFalse,
      );
    },
  );

  test(
    'only attachment validation gets the extended receive timeout',
    () async {
      final fixture = _Fixture();
      final session = await fixture.session();
      await session.complete('private-upload', 'photo', CancelToken());
      final completion = fixture.accountTransport.calls.last.options;
      expect(completion.receiveTimeout, const Duration(seconds: 90));
      await session.access('private-upload');
      expect(
        fixture.accountTransport.calls.last.options.receiveTimeout,
        const Duration(seconds: 18),
      );
      expect(
        session.account.dio.options.receiveTimeout,
        const Duration(seconds: 18),
      );
    },
  );

  test('late validation ACK is discarded after account switch', () async {
    final fixture = _Fixture();
    final response = Completer<ResponseBody>();
    final started = Completer<void>();
    fixture.completionHandler = (_) {
      started.complete();
      return response.future;
    };
    final session = await fixture.session();
    final result = session.complete('private-upload', 'photo', CancelToken());
    final rejected = expectLater(result, throwsStateError);
    await started.future;
    fixture.memory.token = 'bob-token';
    response.complete(
      _json({'id': 'private-upload', 'media_type': 'photo', 'status': 'ready'}),
    );
    await rejected;
    expect(
      fixture.accountTransport.calls.last.options.receiveTimeout,
      const Duration(seconds: 90),
    );
    expect(
      fixture.accountTransport.calls.last.options.headers['Authorization'],
      'Bearer alice-token',
    );
  });

  test(
    'a validation HTTP failure is surfaced without an automatic retry',
    () async {
      final fixture = _Fixture();
      fixture.completionHandler = (_) => _json({'detail': 'Please retry'}, 503);
      await expectLater(
        (await fixture.session()).complete(
          'private-upload',
          'video',
          CancelToken(),
        ),
        throwsA(isA<DioException>()),
      );
      expect(
        fixture.accountTransport.calls.where(
          (call) => call.options.path.endsWith('/complete'),
        ),
        hasLength(1),
      );
    },
  );

  test('canceling pending validation ignores its late ready result', () async {
    final fixture = _Fixture();
    final response = Completer<ResponseBody>();
    final started = Completer<void>();
    fixture.completionHandler = (_) {
      started.complete();
      return response.future;
    };
    final session = await fixture.session();
    final token = CancelToken();
    final result = session.complete('private-upload', 'video', token);
    final canceled = expectLater(
      result,
      throwsA(
        isA<DioException>().having(CancelToken.isCancel, 'canceled', isTrue),
      ),
    );
    await started.future;
    token.cancel('Canceled by user');
    response.complete(
      _json({'id': 'private-upload', 'media_type': 'video', 'status': 'ready'}),
    );
    await canceled;
    expect(
      fixture.accountTransport.calls.where(
        (call) => call.options.path.endsWith('/complete'),
      ),
      hasLength(1),
    );
  });

  test(
    'canceling processing stops the wait without another completion call',
    () async {
      final fixture = _Fixture()
        ..completeResponse = {
          'id': 'private-upload',
          'media_type': 'video',
          'status': 'processing',
        };
      final session = await fixture.session();
      final token = CancelToken();
      final result = session.complete('private-upload', 'video', token);
      final canceled = expectLater(
        result,
        throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'canceled', isTrue),
        ),
      );
      await fixture.firstCompletion.future;
      token.cancel('Canceled by user');
      await canceled;
      expect(
        fixture.accountTransport.calls.where(
          (call) => call.options.path.endsWith('/complete'),
        ),
        hasLength(1),
      );
    },
  );

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
