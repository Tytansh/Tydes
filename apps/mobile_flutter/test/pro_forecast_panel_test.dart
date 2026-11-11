import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/detailed_forecast_models.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/spots/pro_forecast_panel.dart';

DetailedForecastModel _forecast({bool gaps = false, bool allNull = false}) {
  return DetailedForecastModel.fromJson({
    'spot_id': 'uluwatu',
    'available': true,
    'source': 'open-meteo',
    'marine_model': 'Open-Meteo Best Match',
    'weather_model': 'Open-Meteo Best Match',
    'timezone': 'Asia/Makassar',
    'utc_offset_seconds': 28800,
    'fetched_at': '2026-11-12T00:00:00Z',
    'local_date': null,
    'days': [
      {
        'day': '2026-11-12',
        'sunrise': '2026-11-12T05:50:00+08:00',
        'sunset': '2026-11-12T18:20:00+08:00',
      },
      {
        'day': '2026-11-13',
        'sunrise': '2026-11-13T05:51:00+08:00',
        'sunset': '2026-11-13T18:21:00+08:00',
      },
    ],
    'hours': [
      for (final day in [12, 13])
        for (var i = 0; i < 8; i++)
          {
            'time': DateTime.utc(2026, 11, day, i - 2).toIso8601String(),
            'local_date': '2026-11-$day',
            'local_time': '${(i + 6).toString().padLeft(2, '0')}:00',
            'is_day': true,
            'wave_height_m': allNull || (gaps && i == 1) ? null : 1.8 + i / 10,
            'wave_period_s': allNull ? null : 12.0,
            'wave_direction_deg': allNull ? null : 215,
            'swell_height_m': allNull ? null : 1.6 + i / 10,
            'swell_period_s': allNull ? null : 14.0,
            'swell_peak_period_s': allNull ? null : 16.0,
            'swell_direction_deg': allNull ? null : 215,
            'secondary_swell_height_m': null,
            'secondary_swell_period_s': null,
            'secondary_swell_direction_deg': null,
            'wind_wave_height_m': allNull ? null : .4,
            'wind_wave_period_s': allNull ? null : 4.0,
            'wind_wave_direction_deg': allNull ? null : 100,
            'wind_kts': allNull ? null : 4 + i,
            'wind_gusts_kts': allNull ? null : 8 + i,
            'wind_direction_deg': allNull ? null : 100,
            'sea_surface_temperature_c': allNull ? null : 28.5,
          },
    ],
  });
}

TideForecastModel _tides({bool samples = true}) => TideForecastModel.fromJson({
  'spot_id': 'uluwatu',
  'available': true,
  'source': 'TideCheck',
  'station_name': 'Benoa',
  'station_distance_km': 18.4,
  'timezone': 'Asia/Makassar',
  'datum': 'LAT',
  'fetched_at': '2026-11-12T00:00:00Z',
  'events': [
    {
      'type': 'high',
      'time': '2026-11-12T00:00:00Z',
      'local_date': '2026-11-12',
      'local_time': '08:00',
      'height_m': 1.7,
    },
    {
      'type': 'low',
      'time': '2026-11-12T06:00:00Z',
      'local_date': '2026-11-12',
      'local_time': '14:00',
      'height_m': .3,
    },
  ],
  'samples': samples
      ? [
          for (var i = 0; i < 12; i++)
            {
              'time': DateTime.utc(2026, 11, 12, 0, i * 15).toIso8601String(),
              'height_m': 1.7 - i / 12,
              'local_date': '2026-11-12',
              'local_time':
                  '${(8 + i ~/ 4).toString().padLeft(2, '0')}:${((i % 4) * 15).toString().padLeft(2, '0')}',
            },
        ]
      : [],
});

Future<void> _show(
  WidgetTester tester,
  DetailedForecastModel forecast, {
  TideForecastModel? tide,
  Size size = const Size(1440, 1000),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ProForecastPanel(forecast: forecast, tide: tide ?? _tides()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(768, 1024),
    const Size(1440, 1000),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('forecast desk fits $size at text scale $scale', (
        tester,
      ) async {
        await _show(tester, _forecast(gaps: true), size: size, scale: scale);
        expect(find.text('FORECAST DESK'), findsOneWidget);
        expect(find.text('OFFSHORE WAVES'), findsOneWidget);
        expect(
          find.textContaining('not breaking-wave face height'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('KNOW YOUR DATA'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('day selection resets hour and arrows inspect data', (
    tester,
  ) async {
    await _show(tester, _forecast());
    expect(
      find.byKey(const ValueKey('forecast-selected-time')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('forecast-selected-time')))
          .data,
      '06:00',
    );
    await tester.tap(find.byTooltip('Next forecast hour'));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('forecast-selected-time')))
          .data,
      '07:00',
    );
    await tester.tap(find.byKey(const ValueKey('forecast-day-2026-11-13')));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('forecast-selected-time')))
          .data,
      '06:00',
    );
    expect(
      find.text('No tide predictions are available for this selected day.'),
      findsOneWidget,
    );
  });

  testWidgets('server local day and nearest UTC hour choose the initial view', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final forecast = DetailedForecastModel(
      spotId: 'test',
      available: true,
      localDate: '2036-01-02',
      hours: [
        HourlyForecastModel(
          time: now.subtract(const Duration(days: 1)).toIso8601String(),
          localDate: '2036-01-01',
          localTime: '07:00',
          waveHeightM: 1,
        ),
        HourlyForecastModel(
          time: now.subtract(const Duration(hours: 2)).toIso8601String(),
          localDate: '2036-01-02',
          localTime: '06:00',
          waveHeightM: 1,
        ),
        HourlyForecastModel(
          time: now.toIso8601String(),
          localDate: '2036-01-02',
          localTime: '08:00',
          waveHeightM: 2,
        ),
        HourlyForecastModel(
          time: now.add(const Duration(hours: 2)).toIso8601String(),
          localDate: '2036-01-02',
          localTime: '10:00',
          waveHeightM: 3,
        ),
      ],
    );
    await _show(tester, forecast);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('forecast-selected-time')))
          .data,
      '08:00',
    );
    await tester.tap(find.byTooltip('Previous forecast hour'));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('forecast-selected-time')))
          .data,
      '06:00',
    );
    expect(find.text('Forecast data by Open-Meteo'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chart tapping updates the selected hour', (tester) async {
    await _show(tester, _forecast());
    final chart = find.byKey(const ValueKey('wave-swell-chart'));
    await tester.ensureVisible(chart);
    await tester.pumpAndSettle();
    final rectangle = tester.getRect(chart);
    await tester.tapAt(Offset(rectangle.right - 15, rectangle.center.dy));
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('forecast-selected-time')))
          .data,
      '13:00',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing readings do not turn into zero height or calm wind', (
    tester,
  ) async {
    await _show(tester, _forecast(allNull: true));
    expect(
      find.text('No model values supplied for this chart.'),
      findsNWidgets(2),
    );
    expect(find.text('0.0 m'), findsNothing);
    expect(find.text('0 kt'), findsNothing);
    expect(find.text('—'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only supplied tide samples produce a curve with datum', (
    tester,
  ) async {
    await _show(tester, _forecast());
    expect(find.byKey(const ValueKey('tide-sample-chart')), findsOneWidget);
    expect(find.textContaining('Datum: LAT'), findsOneWidget);
    expect(find.text('High · 08:00'), findsOneWidget);
    expect(find.text('Low · 14:00'), findsOneWidget);
  });

  testWidgets('extremes are never interpolated into an invented tide chart', (
    tester,
  ) async {
    await _show(tester, _forecast(), tide: _tides(samples: false));
    expect(find.byKey(const ValueKey('tide-sample-chart')), findsNothing);
    expect(
      find.textContaining('No continuous tide curve is inferred.'),
      findsOneWidget,
    );
  });

  testWidgets('unavailable or locked data stays an honest empty state', (
    tester,
  ) async {
    await _show(
      tester,
      DetailedForecastModel.unavailable(
        'uluwatu',
        note: 'Premium or your selected live spot unlocks hourly data.',
      ),
    );
    expect(find.text('Hourly outlook unavailable'), findsOneWidget);
    expect(
      find.text('Premium or your selected live spot unlocks hourly data.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('wave-swell-chart')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'source transparency distinguishes retrieval from model issue time',
    (tester) async {
      await _show(tester, _forecast());
      expect(
        find.textContaining(
          'This is retrieval time, not the model issue time.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('not observations or a safety rating'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Directions are FROM true north'),
        findsOneWidget,
      );
      expect(find.textContaining('From SW · 215°'), findsOneWidget);
    },
  );
}
