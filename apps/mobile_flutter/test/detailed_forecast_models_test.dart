import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/detailed_forecast_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';

class _ForecastTransport implements HttpClientAdapter {
  _ForecastTransport(this.handler);
  final ResponseBody Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object data, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

SurfRepository _repository(ResponseBody Function(RequestOptions) handler) =>
    SurfRepository(
      Dio(BaseOptions(baseUrl: 'https://test.invalid'))
        ..httpClientAdapter = _ForecastTransport(handler),
      DemoPersistence(),
    );

void main() {
  test(
    'hourly detail preserves unknown values, finite zero and local labels',
    () {
      final result = DetailedForecastModel.fromJson({
        'spot_id': 'spot',
        'available': true,
        'timezone': 'Australia/Sydney',
        'fetched_at': '2026-11-11T05:00:00Z',
        'local_date': '2026-11-11',
        'hours': [
          {
            'time': '2026-11-11T05:00:00Z',
            'local_date': '2026-11-11',
            'local_time': '16:00',
            'wind_kts': 0,
            'swell_height_m': null,
            'wave_height_m': double.nan,
            'swell_period_s': double.infinity,
          },
          {'time': 'not-a-time', 'local_date': 'bad', 'local_time': 'bad'},
        ],
      });
      expect(result.hours, hasLength(1));
      expect(result.hours.first.windKts, 0);
      expect(result.hours.first.swellHeightM, isNull);
      expect(result.hours.first.waveHeightM, isNull);
      expect(result.hours.first.swellPeriodS, isNull);
      expect(result.hours.first.localTime, '16:00');
      expect(result.fetchedAt!.isUtc, isTrue);
    },
  );

  test('older tide response is compatible without a fabricated curve', () {
    final tide = TideForecastModel.fromJson({
      'spot_id': 'spot',
      'available': true,
      'events': [],
    });
    expect(tide.samples, isEmpty);
    expect(tide.datum, isNull);
    expect(tide.fetchedAt, isNull);
  });

  test(
    'tide samples retain negatives and station-local time, discard invalid points',
    () {
      final tide = TideForecastModel.fromJson({
        'spot_id': 'spot',
        'available': true,
        'datum': 'LAT',
        'timezone': 'Australia/Sydney',
        'samples': [
          {
            'time': '2026-11-11T05:00:00Z',
            'height_m': -.2,
            'local_date': '2026-11-11',
            'local_time': '16:00',
          },
          {'time': 'invalid', 'height_m': 2},
          {'time': '2026-11-11T06:00:00Z', 'height_m': double.infinity},
        ],
      });
      expect(tide.samples, hasLength(1));
      expect(tide.samples.first.heightM, -.2);
      expect(tide.samples.first.localTime, '16:00');
    },
  );

  test(
    'detail endpoint has no simulated fallback on network or auth failure',
    () async {
      for (final status in [401, 403, 429, 500, 503]) {
        final repo = _repository((request) {
          expect(request.path, '/forecasts/detail');
          expect(request.queryParameters['spot_id'], 'real-spot');
          return _json({'detail': 'unavailable'}, status);
        });
        await expectLater(
          repo.fetchDetailedForecast('real-spot'),
          throwsA(isA<DioException>()),
        );
      }
    },
  );

  test(
    'a malformed unlock response cannot claim successful account access',
    () async {
      final original = DemoSeed.me;
      final repo = _repository((_) => _json({'unexpected': true}));
      await expectLater(repo.setFreeLiveSpot('new-spot'), throwsStateError);
      expect(identical(DemoSeed.me, original), isTrue);
    },
  );
}
