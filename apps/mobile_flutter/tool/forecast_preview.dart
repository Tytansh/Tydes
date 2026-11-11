// Manual layout-only entrypoint. Never used by lib/main.dart or deployed.
// flutter build web --target=tool/forecast_preview.dart --output=<temporary-dir>
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/detailed_forecast_models.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/spots/pro_forecast_panel.dart';

void main() {
  const firstDay = '2026-11-12';
  final hours = <HourlyForecastModel>[];
  final tides = <TideSampleModel>[];
  final days = <ForecastDaylightModel>[];
  for (var day = 12; day < 17; day++) {
    final date = '2026-11-$day';
    days.add(
      ForecastDaylightModel(
        day: date,
        sunrise: '${date}T05:50:00+08:00',
        sunset: '${date}T18:20:00+08:00',
      ),
    );
    for (var hour = 0; hour < 24; hour++) {
      hours.add(
        HourlyForecastModel(
          time: DateTime.utc(2026, 11, day, hour - 8).toIso8601String(),
          localDate: date,
          localTime: '${hour.toString().padLeft(2, '0')}:00',
          isDay: hour >= 6 && hour < 19,
          waveHeightM: 1.6 + (day - 12) * .15 + math.sin(hour / 5) * .3,
          wavePeriodS: 12.5,
          waveDirectionDeg: 218,
          swellHeightM: 1.3 + (day - 12) * .15 + math.sin(hour / 5) * .2,
          swellPeriodS: 13.2,
          swellPeakPeriodS: 16,
          swellDirectionDeg: 220,
          secondarySwellHeightM: .5,
          secondarySwellPeriodS: 9,
          secondarySwellDirectionDeg: 195,
          windWaveHeightM: .3,
          windWavePeriodS: 4.5,
          windWaveDirectionDeg: 105,
          windKts: 6 + math.sin(hour / 4) * 3,
          windGustsKts: 10 + math.sin(hour / 4) * 4,
          windDirectionDeg: 105,
          seaSurfaceTemperatureC: 28.2,
        ),
      );
    }
    for (var quarter = 0; quarter < 96; quarter++) {
      tides.add(
        TideSampleModel(
          time: DateTime.utc(2026, 11, day, -8, quarter * 15).toIso8601String(),
          heightM: 1.1 + math.sin(quarter / 96 * math.pi * 4) * .7,
          localDate: date,
          localTime:
              '${(quarter ~/ 4).toString().padLeft(2, '0')}:${((quarter % 4) * 15).toString().padLeft(2, '0')}',
        ),
      );
    }
  }
  final forecast = DetailedForecastModel(
    spotId: 'visual-qa-only',
    available: true,
    source: 'Synthetic QA fixture',
    marineModel: 'Synthetic QA fixture',
    weatherModel: 'Synthetic QA fixture',
    timezone: 'Asia/Makassar',
    utcOffsetSeconds: 28800,
    fetchedAt: DateTime.utc(2026, 11, 12),
    localDate: firstDay,
    note: 'Visual test data only. This is not a live forecast.',
    hours: hours,
    days: days,
  );
  final tide = TideForecastModel(
    spotId: 'visual-qa-only',
    available: true,
    stationName: 'QA station',
    stationDistanceKm: 12.4,
    source: 'Synthetic QA fixture',
    events: [],
    note: 'Visual test data only.',
    samples: tides,
    timezone: 'Asia/Makassar',
    datum: 'Test datum',
  );
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('LAYOUT PREVIEW · SYNTHETIC TEST DATA'),
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1250),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  'Uluwatu · Visual QA only — not a live forecast',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 20),
                ProForecastPanel(forecast: forecast, tide: tide),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
