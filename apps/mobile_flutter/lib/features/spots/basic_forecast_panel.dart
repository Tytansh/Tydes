import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/network/basic_forecast_models.dart';

/// A deliberately small daily preview, separate from the full forecast desk.
class BasicForecastPanel extends StatelessWidget {
  const BasicForecastPanel({
    super.key,
    required this.forecast,
    required this.onRetry,
    this.loading = false,
    this.error,
  });

  final BasicForecastModel forecast;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final ocean = dark ? const Color(0xFF77C8F0) : const Color(0xFF127EB0);
    final ink = dark ? scheme.onSurface : const Color(0xFF173B40);
    final valid = error == null && forecast.isCurrentAt(DateTime.now());
    final maxHeight = valid
        ? forecast.days.fold<double>(
            0,
            (max, day) => math.max(max, day.waveHeightM),
          )
        : 0.0;

    return Container(
      key: const ValueKey('basic-forecast-panel'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: dark ? theme.cardColor : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: dark ? scheme.outlineVariant : const Color(0xFFE0E9E7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.waves_rounded, color: ocean, size: 22),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      'Basic daily outlook',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: ink,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: ocean.withValues(alpha: dark ? .18 : .08),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  'Model estimate',
                  style: TextStyle(
                    color: ocean,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Daily mean significant wave height',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 5),
          Text(
            'Sunrise and sunset are spot local time.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
          ),
          const SizedBox(height: 20),
          if (loading && !valid)
            const Row(
              children: [
                SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 10),
                Expanded(child: Text('Loading basic daily outlook')),
              ],
            )
          else if (!valid) ...[
            Text(
              'Basic outlook unavailable',
              style: TextStyle(color: ink, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              error ??
                  forecast.note ??
                  'A current model outlook is not available for this spot.',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('basic-forecast-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry basic outlook'),
            ),
          ] else ...[
            LayoutBuilder(
              builder: (context, constraints) {
                final showBars = constraints.maxWidth >= 280;
                final wide =
                    constraints.maxWidth >= 880 &&
                    MediaQuery.textScalerOf(context).scale(12) <= 18;
                return Column(
                  children: [
                    for (final day in forecast.days)
                      Padding(
                        key: ValueKey('basic-forecast-day-${day.day}'),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    flex: 4,
                                    child: _BasicWaveRow(
                                      day: day,
                                      maxHeight: maxHeight,
                                      showBars: showBars,
                                      ocean: ocean,
                                      ink: ink,
                                      dark: dark,
                                    ),
                                  ),
                                  const SizedBox(width: 28),
                                  Expanded(
                                    flex: 6,
                                    child: _DailyModelExtras(
                                      day: day,
                                      wide: true,
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                children: [
                                  _BasicWaveRow(
                                    day: day,
                                    maxHeight: maxHeight,
                                    showBars: showBars,
                                    ocean: ocean,
                                    ink: ink,
                                    dark: dark,
                                  ),
                                  const SizedBox(height: 12),
                                  _DailyModelExtras(day: day),
                                ],
                              ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            Divider(color: scheme.outlineVariant),
            const SizedBox(height: 8),
            Text(
              'Open-Meteo · ${forecast.marineModel}',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              'Wind model: ${forecast.weatherModel ?? 'Unavailable'}',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                height: 1.5,
              ),
            ),
            Text(
              'Fetched ${DateFormat('d MMM yyyy, HH:mm').format(forecast.fetchedAt!.toUtc())} UTC · ${forecast.timezone}',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                height: 1.5,
              ),
            ),
            if (forecast.note?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(
                forecast.note!,
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ],
          const SizedBox(height: 14),
          Text(
            'Modelled offshore sea height, not breaking-wave face height. Local reefs, shelter and tides can change conditions at the beach.',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _BasicWaveRow extends StatelessWidget {
  const _BasicWaveRow({
    required this.day,
    required this.maxHeight,
    required this.showBars,
    required this.ocean,
    required this.ink,
    required this.dark,
  });
  final BasicForecastDayModel day;
  final double maxHeight;
  final bool showBars;
  final Color ocean, ink;
  final bool dark;

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        '${day.day}, daily mean significant wave height ${day.waveHeightM.toStringAsFixed(1)} metres',
    excludeSemantics: true,
    child: Row(
      children: [
        Expanded(
          flex: showBars ? 2 : 1,
          child: Text(
            DateFormat('EEE, d MMM').format(DateTime.parse(day.day)),
            style: TextStyle(color: ink, fontWeight: FontWeight.w600),
          ),
        ),
        if (showBars) ...[
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Container(
              height: 12,
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: ocean.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(99),
              ),
              child: FractionallySizedBox(
                widthFactor: maxHeight == 0 ? 0 : day.waveHeightM / maxHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        ocean,
                        dark
                            ? const Color(0xFF67D8CB)
                            : const Color(0xFF069F9F),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: const SizedBox(height: 12),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(width: 16),
        SizedBox(
          width: 58,
          child: Text(
            '${day.waveHeightM.toStringAsFixed(1)} m',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: ink,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    ),
  );
}

class _DailyModelExtras extends StatelessWidget {
  const _DailyModelExtras({required this.day, this.wide = false});
  final BasicForecastDayModel day;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final sunrise = _daylightLabel(day.sunriseLocal);
    final sunset = _daylightLabel(day.sunsetLocal);
    final contradictoryDaylight =
        sunrise != 'Unavailable' &&
        sunset != 'Unavailable' &&
        sunrise.compareTo(sunset) >= 0;
    final metrics = [
      _DailyMetric(
        key: ValueKey('basic-wind-${day.day}'),
        label: 'Wind · daily mean',
        value: _windLabel(day),
      ),
      _DailyMetric(
        key: ValueKey('basic-water-${day.day}'),
        label: 'Model water temp',
        value: _waterLabel(day.seaSurfaceTemperatureC),
      ),
      _DailyMetric(
        key: ValueKey('basic-sunrise-${day.day}'),
        label: 'Sunrise',
        value: contradictoryDaylight ? 'Unavailable' : sunrise,
      ),
      _DailyMetric(
        key: ValueKey('basic-sunset-${day.day}'),
        label: 'Sunset',
        value: contradictoryDaylight ? 'Unavailable' : sunset,
      ),
    ];
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < metrics.length; index++) ...[
            if (index > 0) const SizedBox(width: 16),
            Expanded(flex: index == 0 ? 3 : 2, child: metrics[index]),
          ],
        ],
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns =
              constraints.maxWidth >= 220 &&
                  MediaQuery.textScalerOf(context).scale(12) <= 20
              ? 2
              : 1;
          final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final metric in metrics)
                SizedBox(width: width, child: metric),
            ],
          );
        },
      ),
    );
  }
}

class _DailyMetric extends StatelessWidget {
  const _DailyMetric({super.key, required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 11,
          height: 1.4,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
      ),
    ],
  );
}

String _windLabel(BasicForecastDayModel day) {
  final speed = day.windKts;
  if (speed == null || !speed.isFinite || speed < 0 || speed > 250) {
    return 'Unavailable';
  }
  final direction = day.windDirectionDeg;
  final directionText = switch (day.windDirectionStatus) {
    'available'
        when speed >= 1 &&
            direction != null &&
            direction >= 0 &&
            direction <= 359 =>
      'FROM ${_compass(direction)}',
    'calm' when speed < 1 => 'Calm',
    'variable' when speed >= 1 => 'Variable',
    _ => 'Direction unavailable',
  };
  return '${speed.toStringAsFixed(1)} kt · $directionText';
}

String _compass(int direction) {
  const points = [
    'N',
    'NNE',
    'NE',
    'ENE',
    'E',
    'ESE',
    'SE',
    'SSE',
    'S',
    'SSW',
    'SW',
    'WSW',
    'W',
    'WNW',
    'NW',
    'NNW',
  ];
  return points[((direction + 11.25) / 22.5).floor() % points.length];
}

String _waterLabel(double? temperature) =>
    temperature != null &&
        temperature.isFinite &&
        temperature >= -5 &&
        temperature <= 50
    ? '${temperature.toStringAsFixed(1)}°C'
    : 'Unavailable';

String _daylightLabel(String? value) =>
    value != null && RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(value)
    ? value
    : 'Unavailable';
