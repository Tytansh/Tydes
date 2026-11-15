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

  test(
    'older wave-only payload remains valid with missing extras unavailable',
    () {
      final model = BasicForecastModel.fromJson(_payload());
      expect(model.isCurrentAt(DateTime.now()), isTrue);
      expect(model.weatherModel, isNull);
      for (final day in model.days) {
        expect(day.windKts, isNull);
        expect(day.windDirectionDeg, isNull);
        expect(day.windDirectionStatus, 'unavailable');
        expect(day.seaSurfaceTemperatureC, isNull);
        expect(day.sunriseLocal, isNull);
        expect(day.sunsetLocal, isNull);
      }
    },
  );

  test(
    'preserves mean wind, explicit North, cold water zero and spot-local sun',
    () {
      final payload = _payload()..['weather_model'] = 'Best Match (automatic)';
      (payload['days'] as List).first.addAll({
        'wind_kts': 6.25,
        'wind_direction_deg': 0,
        'wind_direction_status': 'available',
        'sea_surface_temperature_c': 0,
        'sunrise_local': '05:43',
        'sunset_local': '18:17',
      });
      final model = BasicForecastModel.fromJson(payload);
      final day = model.days.first;
      expect(model.weatherModel, 'Best Match (automatic)');
      expect(day.windKts, 6.25);
      expect(day.windDirectionDeg, 0);
      expect(day.windDirectionStatus, 'available');
      expect(day.seaSurfaceTemperatureC, 0);
      expect(day.sunriseLocal, '05:43');
      expect(day.sunsetLocal, '18:17');
      expect(day.waveHeightM, 0);
    },
  );

  test('zero/missing wind never fabricates a direction or implicit calm', () {
    for (final raw in <Map<String, dynamic>>[
      {'wind_kts': 0},
      {
        'wind_kts': null,
        'wind_direction_deg': 0,
        'wind_direction_status': 'available',
      },
      {
        'wind_kts': 0,
        'wind_direction_deg': 0,
        'wind_direction_status': 'available',
      },
      {
        'wind_kts': 6,
        'wind_direction_deg': 360,
        'wind_direction_status': 'available',
      },
      {
        'wind_kts': 6,
        'wind_direction_deg': 0.0,
        'wind_direction_status': 'available',
      },
      {
        'wind_kts': 6,
        'wind_direction_deg': 20,
        'wind_direction_status': 'unknown',
      },
    ]) {
      final day = BasicForecastDayModel.fromJson({
        'day': basicForecastDateKey(DateTime.now()),
        'wave_height_m': 1.2,
        ...raw,
      });
      expect(day.windDirectionStatus, 'unavailable');
      expect(day.windDirectionDeg, isNull);
      expect(day.waveHeightM, 1.2);
    }
  });

  test(
    'explicit calm and variable keep their supplied speeds without North',
    () {
      for (final status in ['calm', 'variable']) {
        final day = BasicForecastDayModel.fromJson({
          'day': basicForecastDateKey(DateTime.now()),
          'wave_height_m': 1.2,
          'wind_kts': status == 'calm' ? 0 : 8.5,
          'wind_direction_status': status,
          'wind_direction_deg': 0,
        });
        expect(day.windKts, status == 'calm' ? 0 : 8.5);
        expect(day.windDirectionStatus, status);
        expect(day.windDirectionDeg, isNull);
      }
    },
  );

  for (final invalid in <Object?>[
    null,
    '27',
    double.nan,
    double.infinity,
    -999,
    999,
  ]) {
    test(
      'invalid optional numeric $invalid does not drop valid wave means',
      () {
        final day = BasicForecastDayModel.fromJson({
          'day': basicForecastDateKey(DateTime.now()),
          'wave_height_m': 1.2,
          'wind_kts': invalid,
          'wind_direction_deg': 0,
          'wind_direction_status': 'available',
          'sea_surface_temperature_c': invalid,
        });
        expect(day.waveHeightM, 1.2);
        expect(day.windKts, isNull);
        expect(day.windDirectionDeg, isNull);
        expect(day.windDirectionStatus, 'unavailable');
        expect(day.seaSurfaceTemperatureC, isNull);
      },
    );
  }

  test('cold negative model water temperature stays valid', () {
    final day = BasicForecastDayModel.fromJson({
      'day': basicForecastDateKey(DateTime.now()),
      'wave_height_m': 1.2,
      'sea_surface_temperature_c': -1.5,
    });
    expect(day.seaSurfaceTemperatureC, -1.5);
  });

  test(
    'malformed optional daylight is unavailable, never device-converted',
    () {
      for (final value in <Object?>[
        '24:00',
        '05:60',
        '5:04',
        '2026-11-16T05:04:00Z',
        544,
        '',
      ]) {
        final day = BasicForecastDayModel.fromJson({
          'day': basicForecastDateKey(DateTime.now()),
          'wave_height_m': 1.2,
          'sunrise_local': value,
          'sunset_local': '18:17',
        });
        expect(day.sunriseLocal, isNull);
        expect(day.sunsetLocal, '18:17');
        expect(day.waveHeightM, 1.2);
      }
      for (final times in [
        ['18:17', '05:43'],
        ['12:00', '12:00'],
      ]) {
        final day = BasicForecastDayModel.fromJson({
          'day': basicForecastDateKey(DateTime.now()),
          'wave_height_m': 1.2,
          'sunrise_local': times.first,
          'sunset_local': times.last,
        });
        expect(day.sunriseLocal, isNull);
        expect(day.sunsetLocal, isNull);
        expect(day.waveHeightM, 1.2);
      }
    },
  );

  test(
    'optional weather model handles partial or malformed metadata without losing waves',
    () {
      for (final value in <Object?>[
        'Temporarily unavailable',
        'untrusted',
        4,
        null,
      ]) {
        final model = BasicForecastModel.fromJson({
          ..._payload(),
          'weather_model': value,
        });
        expect(model.available, isTrue);
        expect(model.days, hasLength(5));
        expect(
          model.weatherModel,
          value == 'Temporarily unavailable' ? value : null,
        );
      }
    },
  );

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
