import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/basic_forecast_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';

import 'auth_session_test.dart' show MemorySessions, FakeTransport, body;

Map<String, dynamic> _payload({DateTime? now}) {
  final instant = (now ?? DateTime.now()).toUtc();
  final local = instant.add(const Duration(hours: 8));
  return {
    'spot_id': 'real-spot',
    'available': true,
    'source': 'open-meteo',
    'marine_model': 'Best Match (automatic)',
    'timezone': 'Asia/Makassar',
    'utc_offset_seconds': 28800,
    'fetched_at': instant
        .subtract(const Duration(minutes: 7))
        .toIso8601String(),
    'local_date': basicForecastDateKey(local),
    'note': 'Daily means from cached marine model data.',
    'days': [
      for (var day = 0; day < 5; day++)
        <String, dynamic>{
          'day': basicForecastDateKey(local.add(Duration(days: day))),
          'wave_height_m': day == 0 ? 0.0 : 1.1 + day / 10,
        },
    ],
  };
}

SurfRepository _repo(
  Future<ResponseBody> Function(RequestOptions) handler, {
  MemorySessions? sessions,
}) => SurfRepository(
  Dio(BaseOptions(baseUrl: 'https://basic.fixture.invalid'))
    ..httpClientAdapter = FakeTransport(handler),
  sessions ?? MemorySessions(),
);

void main() {
  test('daily means preserve finite zero and actual model provenance', () {
    final payload = _payload();
    final model = BasicForecastModel.fromJson(payload);
    expect(model.spotId, 'real-spot');
    expect(model.available, isTrue);
    expect(model.days.first.waveHeightM, 0);
    expect(model.days[1].waveHeightM, closeTo(1.2, .000001));
    expect(model.marineModel, 'Best Match (automatic)');
    expect(model.fetchedAt!.toIso8601String(), payload['fetched_at']);
    expect(model.note, payload['note']);
    expect(model.isCurrentAt(DateTime.now()), isTrue);
  });

  test('unavailable data contains no fabricated reading or retrieval time', () {
    final model = BasicForecastModel.fromJson({
      ..._payload(),
      'available': false,
      'source': 'unavailable',
      'marine_model': null,
      'timezone': null,
      'utc_offset_seconds': null,
      'fetched_at': null,
      'days': <Object>[],
      'note': 'The marine model is unavailable.',
    });
    expect(model.available, isFalse);
    expect(model.days, isEmpty);
    expect(model.fetchedAt, isNull);
    expect(model.isCurrentAt(DateTime.now()), isFalse);
  });

  final invalidFields = <String, Object?>{
    'spot_id': '',
    'available': 'true',
    'source': 'estimated',
    'marine_model': '',
    'timezone': null,
    'utc_offset_seconds': 86400,
    'fetched_at': '2026-11-15T12:00:00',
    'local_date': '2026-02-30',
    'days': null,
  };
  for (final entry in invalidFields.entries) {
    test('rejects incomplete/invalid ${entry.key}', () {
      expect(
        () => BasicForecastModel.fromJson({
          ..._payload(),
          entry.key: entry.value,
        }),
        throwsFormatException,
      );
    });
  }

  for (final height in <Object?>[
    null,
    '1.2',
    -1,
    double.nan,
    double.infinity,
  ]) {
    test('rejects invalid wave height $height rather than inventing zero', () {
      final payload = _payload();
      (payload['days'] as List).first['wave_height_m'] = height;
      expect(() => BasicForecastModel.fromJson(payload), throwsFormatException);
    });
  }

  test(
    'rejects duplicate, out-of-order, past and oversized daily payloads',
    () {
      for (final invalid in [
        'duplicate',
        'reorder',
        'past',
        'future',
        'oversized',
      ]) {
        final payload = _payload();
        final days = payload['days'] as List;
        switch (invalid) {
          case 'duplicate':
            days[1]['day'] = days.first['day'];
          case 'reorder':
            payload['days'] = days.reversed.toList();
          case 'past':
            days.first['day'] = '2026-01-01';
          case 'future':
            days.last['day'] = '2099-01-01';
          case 'oversized':
            days.add(<String, dynamic>{...days.last, 'day': '2099-01-01'});
        }
        expect(
          () => BasicForecastModel.fromJson(payload),
          throwsFormatException,
        );
      }
    },
  );

  test('uses spot local midnight and actual 24-hour timestamp freshness', () {
    final now = DateTime.utc(2026, 11, 15, 15, 59);
    final payload = _payload(now: now);
    final model = BasicForecastModel.fromJson(payload);
    expect(model.isCurrentAt(now), isTrue);
    expect(model.isCurrentAt(now.add(const Duration(minutes: 1))), isFalse);
    expect(
      BasicForecastModel.fromJson({
        ...payload,
        'fetched_at': now.subtract(const Duration(hours: 25)).toIso8601String(),
      }).isCurrentAt(now),
      isFalse,
    );
    expect(
      BasicForecastModel.fromJson({
        ...payload,
        'fetched_at': now.add(const Duration(minutes: 2)).toIso8601String(),
      }).isCurrentAt(now),
      isFalse,
    );
  });

  test(
    'repository uses only the basic endpoint and retries gateway once',
    () async {
      final calls = <RequestOptions>[];
      final repo = _repo((request) async {
        calls.add(request);
        return calls.length == 1
            ? body({'detail': 'Temporary upstream outage'}, 503)
            : body(_payload());
      });
      final model = await repo.fetchBasicForecast('real-spot');
      expect(model.days, hasLength(5));
      expect(calls, hasLength(2));
      for (final request in calls) {
        expect(request.path, '/forecasts/basic');
        expect(request.queryParameters, {'spot_id': 'real-spot'});
        expect(request.headers['Authorization'], 'Bearer old-test-session');
        expect(request.connectTimeout, const Duration(seconds: 40));
        expect(request.receiveTimeout, const Duration(seconds: 40));
      }
    },
  );

  for (final status in [401, 403, 429, 503]) {
    test('HTTP $status never turns into seeded forecast data', () async {
      var calls = 0;
      final repo = _repo((request) async {
        calls++;
        return body({'detail': 'Synthetic unavailable'}, status);
      });
      await expectLater(
        repo.fetchBasicForecast('real-spot'),
        throwsA(isA<DioException>()),
      );
      expect(calls, status == 503 ? 2 : 1);
    });
  }

  test(
    'rejects wrong-spot, stale and malformed successful responses',
    () async {
      for (final change in <Map<String, dynamic>>[
        {'spot_id': 'wrong-spot'},
        {
          'fetched_at': DateTime.now()
              .toUtc()
              .subtract(const Duration(hours: 25))
              .toIso8601String(),
        },
        {'source': 'estimated'},
        {'local_date': '2026-02-30'},
      ]) {
        var calls = 0;
        final repo = _repo((request) async {
          calls++;
          return body({..._payload(), ...change});
        });
        await expectLater(
          repo.fetchBasicForecast('real-spot'),
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
        );
        expect(calls, 1);
      }
    },
  );

  test('signed-out requests never reach the API', () async {
    final sessions = MemorySessions()..token = null;
    var calls = 0;
    final repo = _repo((request) async {
      calls++;
      return body(_payload());
    }, sessions: sessions);
    await expectLater(repo.fetchBasicForecast('real-spot'), throwsStateError);
    expect(calls, 0);
  });

  test(
    'account switch discards an old response without exposing data',
    () async {
      final sessions = MemorySessions();
      final started = Completer<void>();
      final response = Completer<ResponseBody>();
      final repo = _repo((request) {
        started.complete();
        return response.future;
      }, sessions: sessions);
      final pending = repo.fetchBasicForecast('real-spot');
      await started.future;
      sessions.token = 'replacement-session';
      response.complete(body(_payload()));
      await expectLater(pending, throwsStateError);
    },
  );

  test('signout during gateway failure prevents a retry request', () async {
    final sessions = MemorySessions();
    var calls = 0;
    final repo = _repo((request) async {
      calls++;
      sessions.token = null;
      return body({'detail': 'Temporary outage'}, 503);
    }, sessions: sessions);
    await expectLater(repo.fetchBasicForecast('real-spot'), throwsStateError);
    expect(calls, 1);
  });
}
