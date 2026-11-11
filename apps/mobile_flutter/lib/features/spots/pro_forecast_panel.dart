import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/legal/legal_links.dart';
import '../../core/network/api_models.dart';
import '../../core/network/detailed_forecast_models.dart';

/// Chart colours are chosen for the surrounding surface, not just the lines.
/// Canvas labels need the same dark-mode treatment as regular Flutter text.
class _ForecastColors {
  _ForecastColors.of(BuildContext context) : theme = Theme.of(context);

  final ThemeData theme;
  bool get dark => theme.brightness == Brightness.dark;
  Color get ink => dark ? theme.colorScheme.onSurface : const Color(0xFF173B40);
  Color get muted =>
      dark ? theme.colorScheme.onSurfaceVariant : const Color(0xFF617779);
  Color get ocean => dark ? const Color(0xFF77C8F0) : const Color(0xFF127EB0);
  Color get teal => dark ? const Color(0xFF67D8CB) : const Color(0xFF069F9F);
  Color get sand => dark ? const Color(0xFFE8BC76) : const Color(0xFFAE782B);
  Color get border =>
      dark ? theme.colorScheme.outlineVariant : const Color(0xFFE0E9E7);
  Color get panel => dark ? theme.cardColor : Colors.white;
  Color get softSurface =>
      dark ? theme.colorScheme.surfaceContainerHigh : const Color(0xFFF0F5F2);
  Color get daySurface =>
      dark ? theme.colorScheme.surfaceContainerHigh : const Color(0xFFF7F9F7);
  Color get activeDay => dark ? const Color(0xFF265954) : ink;
}

/// A transparent model-data desk. Wave heights are not breaking-wave heights.
class ProForecastPanel extends StatefulWidget {
  const ProForecastPanel({
    super.key,
    required this.forecast,
    required this.tide,
  });

  final DetailedForecastModel forecast;
  final TideForecastModel tide;

  @override
  State<ProForecastPanel> createState() => _ProForecastPanelState();
}

class _ProForecastPanelState extends State<ProForecastPanel> {
  String? _selectedDay;
  int? _selectedHour;

  List<String> get _days {
    final values = widget.forecast.hours.map((hour) => hour.localDate).toSet();
    return values.toList()..sort();
  }

  String? get _day {
    final days = _days;
    if (days.contains(_selectedDay)) return _selectedDay;
    if (days.contains(widget.forecast.localDate)) {
      return widget.forecast.localDate;
    }
    return days.firstOrNull;
  }

  List<HourlyForecastModel> get _hours =>
      widget.forecast.hours.where((hour) => hour.localDate == _day).toList();

  int _initialHour(List<HourlyForecastModel> hours) {
    if (_day != widget.forecast.localDate) return 0;
    final now = DateTime.now().toUtc();
    var closest = 0;
    var difference = const Duration(days: 100000);
    for (var index = 0; index < hours.length; index++) {
      final instant = DateTime.tryParse(hours[index].time)?.toUtc();
      if (instant == null) continue;
      final distance = instant.difference(now).abs();
      if (distance < difference) {
        closest = index;
        difference = distance;
      }
    }
    return closest;
  }

  @override
  void didUpdateWidget(covariant ProForecastPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.forecast.spotId != widget.forecast.spotId) {
      _selectedDay = null;
      _selectedHour = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = _ForecastColors.of(context);
    final forecast = widget.forecast;
    if (!forecast.available || forecast.hours.isEmpty) {
      return _Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Eyebrow('FORECAST DESK'),
            const SizedBox(height: 12),
            Text(
              'Hourly outlook unavailable',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              forecast.note ??
                  'Detailed model data is not available for this spot right now. No estimated readings are substituted.',
              style: TextStyle(color: colors.muted),
            ),
          ],
        ),
      );
    }
    final hours = _hours;
    final selected = (_selectedHour ?? _initialHour(hours)).clamp(
      0,
      hours.length - 1,
    );
    final hour = hours[selected];
    final daylight = forecast.days
        .where((item) => item.day == _day)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const _Eyebrow('FORECAST DESK'),
                  _Pill(
                    '${_days.length}-day hourly outlook',
                    color: colors.ocean,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'Read the swell. Time your session.',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.8,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'All times at the spot${forecast.timezone == null ? '' : ' · ${forecast.timezone}'}. Heights in metres; wind in knots.',
                style: TextStyle(color: colors.muted, fontSize: 12),
              ),
              const SizedBox(height: 20),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _days.map((day) {
                    final dayHours = forecast.hours
                        .where((hour) => hour.localDate == day)
                        .toList();
                    final active = day == _day;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Semantics(
                        selected: active,
                        child: OutlinedButton(
                          key: ValueKey('forecast-day-$day'),
                          onPressed: () => setState(() {
                            _selectedDay = day;
                            _selectedHour = null;
                          }),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: active
                                ? colors.activeDay
                                : colors.daySurface,
                            foregroundColor: active ? Colors.white : colors.ink,
                            side: BorderSide(
                              color: active ? colors.activeDay : colors.border,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _dateLabel(day),
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 7),
                              Text(
                                '${_range(dayHours.map((h) => h.waveHeightM))} m Hs',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: active
                                      ? const Color(0xFFD0E9E8)
                                      : colors.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 22),
              Divider(color: colors.border, height: 1),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _dateLabel(_day!),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: colors.ink,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Previous forecast hour',
                    onPressed: selected > 0
                        ? () => setState(() => _selectedHour = selected - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    hour.localTime,
                    key: const ValueKey('forecast-selected-time'),
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: colors.ink,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next forecast hour',
                    onPressed: selected < hours.length - 1
                        ? () => setState(() => _selectedHour = selected + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              if (hour.isDay != null || daylight != null) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 14,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (hour.isDay != null)
                      _IconLabel(
                        icon: hour.isDay!
                            ? Icons.wb_sunny_outlined
                            : Icons.nights_stay_outlined,
                        text: hour.isDay! ? 'Daylight' : 'After dark',
                      ),
                    if (daylight?.sunrise != null)
                      _IconLabel(
                        icon: Icons.wb_twilight,
                        text: 'Sunrise ${_localClock(daylight!.sunrise)}',
                      ),
                    if (daylight?.sunset != null)
                      _IconLabel(
                        icon: Icons.wb_twilight_outlined,
                        text: 'Sunset ${_localClock(daylight!.sunset)}',
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 720 ? 4 : 2;
                  final width =
                      (constraints.maxWidth - (columns - 1) * 10) / columns;
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _Metric(
                        width: width,
                        label: 'OFFSHORE WAVES',
                        value: _value(hour.waveHeightM, 'm'),
                        detail: 'Significant height · Hs',
                        color: colors.ocean,
                      ),
                      _Metric(
                        width: width,
                        label: 'SWELL PERIOD',
                        value: _value(hour.swellPeriodS, 's'),
                        detail: hour.swellPeakPeriodS == null
                            ? 'Mean period'
                            : 'Peak ${_value(hour.swellPeakPeriodS, 's')}',
                        color: colors.teal,
                      ),
                      _Metric(
                        key: const ValueKey('selected-wind-metric'),
                        width: width,
                        label: 'WIND',
                        value: _value(hour.windKts, 'kt'),
                        detail: _direction(hour.windDirectionDeg),
                        color: colors.ink,
                      ),
                      _Metric(
                        width: width,
                        label: 'WATER',
                        value: _value(hour.seaSurfaceTemperatureC, '°C'),
                        detail: 'Sea surface estimate',
                        color: colors.sand,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              Text(
                'Modelled offshore wave height is not breaking-wave face height. Local bathymetry, shelter, sandbanks and tide can change what reaches the beach.',
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final charts = [
              _ChartCard(
                title: 'Wave & swell height',
                subtitle: 'Offshore significant height · metres',
                chartKey: const ValueKey('wave-swell-chart'),
                hours: hours,
                selected: selected,
                onSelected: (index) => setState(() => _selectedHour = index),
                unit: 'm',
                series: [
                  _Series(
                    'Combined waves',
                    colors.ocean,
                    hours.map((h) => h.waveHeightM).toList(),
                  ),
                  _Series(
                    'Swell',
                    colors.teal,
                    hours.map((h) => h.swellHeightM).toList(),
                  ),
                  _Series(
                    'Wind waves',
                    colors.sand,
                    hours.map((h) => h.windWaveHeightM).toList(),
                  ),
                ],
              ),
              _ChartCard(
                title: 'Wind & gusts',
                subtitle: '10 m above the surface · knots',
                chartKey: const ValueKey('wind-gust-chart'),
                hours: hours,
                selected: selected,
                onSelected: (index) => setState(() => _selectedHour = index),
                unit: 'kt',
                series: [
                  _Series(
                    'Wind',
                    colors.teal,
                    hours.map((h) => h.windKts).toList(),
                  ),
                  _Series(
                    'Gusts',
                    colors.sand,
                    hours.map((h) => h.windGustsKts).toList(),
                  ),
                ],
              ),
            ];
            if (constraints.maxWidth >= 1000) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: charts[0]),
                  const SizedBox(width: 14),
                  Expanded(child: charts[1]),
                ],
              );
            }
            return Column(
              children: [charts[0], const SizedBox(height: 14), charts[1]],
            );
          },
        ),
        const SizedBox(height: 14),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionHeading(
                'Swell breakdown',
                'Height, period and where it comes from',
              ),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 720 ? 3 : 1;
                  final width =
                      (constraints.maxWidth - (columns - 1) * 12) / columns;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _Component(
                        width: width,
                        title: 'Swell',
                        color: colors.teal,
                        height: hour.swellHeightM,
                        period: hour.swellPeriodS,
                        direction: hour.swellDirectionDeg,
                        note: hour.swellPeakPeriodS == null
                            ? 'Mean period'
                            : 'Peak period ${_value(hour.swellPeakPeriodS, 's')}',
                      ),
                      _Component(
                        width: width,
                        title: 'Secondary swell',
                        color: colors.ocean,
                        height: hour.secondarySwellHeightM,
                        period: hour.secondarySwellPeriodS,
                        direction: hour.secondarySwellDirectionDeg,
                        note: 'Model-dependent availability',
                      ),
                      _Component(
                        width: width,
                        title: 'Wind waves',
                        color: colors.sand,
                        height: hour.windWaveHeightM,
                        period: hour.windWavePeriodS,
                        direction: hour.windWaveDirectionDeg,
                        note: 'Locally wind-generated waves',
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              Text(
                'Directions are FROM true north: 0° N, 90° E, 180° S, 270° W. Components are not additive wave heights. “—” means the model did not supply a value.',
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _TidePanel(tide: widget.tide, forecast: forecast, day: _day!),
        const SizedBox(height: 14),
        _Panel(
          color: colors.softSurface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Eyebrow('KNOW YOUR DATA'),
              const SizedBox(height: 10),
              Text(
                'Marine: ${forecast.marineModel ?? forecast.source}. Wind: ${forecast.weatherModel ?? 'Open-Meteo automatic selection'}.',
                style: TextStyle(fontSize: 12, color: colors.ink, height: 1.6),
              ),
              const SizedBox(height: 5),
              Text(
                forecast.fetchedAt == null
                    ? 'Fetch time unavailable. Model issue time is not supplied.'
                    : 'Fetched ${DateFormat('d MMM, HH:mm').format(forecast.fetchedAt!.toUtc())} UTC. This is retrieval time, not the model issue time.',
                style: TextStyle(
                  fontSize: 12,
                  color: colors.muted,
                  height: 1.6,
                ),
              ),
              if (forecast.note != null) ...[
                const SizedBox(height: 8),
                Text(
                  forecast.note!,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.muted,
                    height: 1.6,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Forecast models are guidance, not observations or a safety rating. Confidence generally falls further ahead. Check the beach and local hazards before surfing.',
                style: TextStyle(
                  fontSize: 12,
                  color: colors.muted,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => launchTydesExternalLink(
                      context,
                      'https://open-meteo.com/',
                    ),
                    icon: const Icon(Icons.open_in_new, size: 13),
                    label: const Text('Forecast data by Open-Meteo'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      textStyle: const TextStyle(fontSize: 11),
                    ),
                  ),
                  if (widget.tide.source.toLowerCase().contains('tidecheck'))
                    TextButton.icon(
                      onPressed: () => launchTydesExternalLink(
                        context,
                        'https://tidecheck.com/',
                      ),
                      icon: const Icon(Icons.open_in_new, size: 13),
                      label: const Text('Tide predictions by TideCheck'),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        textStyle: const TextStyle(fontSize: 11),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TidePanel extends StatelessWidget {
  const _TidePanel({
    required this.tide,
    required this.forecast,
    required this.day,
  });

  final TideForecastModel tide;
  final DetailedForecastModel forecast;
  final String day;

  @override
  Widget build(BuildContext context) {
    final colors = _ForecastColors.of(context);
    final samples = tide.samples
        .where(
          (sample) =>
              (sample.localDate ?? _sampleLocal(sample.time, forecast).$1) ==
              day,
        )
        .toList();
    final events = tide.events
        .where((event) => event.localDate == day)
        .toList();
    final station = tide.stationName;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeading(
            'Tide outlook',
            'Station predictions · not a navigation chart',
          ),
          const SizedBox(height: 10),
          Text(
            [
              ?station,
              if (tide.stationDistanceKm != null)
                '${tide.stationDistanceKm!.toStringAsFixed(1)} km from spot',
              if (tide.datum != null) 'Datum: ${tide.datum}',
            ].join(' · '),
            style: TextStyle(color: colors.muted, fontSize: 12, height: 1.6),
          ),
          const SizedBox(height: 16),
          if (!tide.available || (samples.isEmpty && events.isEmpty))
            Text(
              tide.available
                  ? 'No tide predictions are available for this selected day.'
                  : (tide.note ?? 'Tide data is unavailable right now.'),
              style: TextStyle(color: colors.muted),
            )
          else ...[
            if (samples.length >= 2)
              Semantics(
                label:
                    'Predicted tide heights in metres${tide.datum == null ? '' : ' relative to ${tide.datum}'}. ${samples.length} supplied samples, not an inferred curve.',
                child: SizedBox(
                  key: const ValueKey('tide-sample-chart'),
                  height: 220,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _TidePainter(
                      samples
                          .map(
                            (sample) => _TidePoint(
                              DateTime.parse(sample.time),
                              sample.heightM,
                              sample.localTime ??
                                  _sampleLocal(sample.time, forecast).$2,
                            ),
                          )
                          .toList(),
                      textScaler: MediaQuery.textScalerOf(context),
                      colors: colors,
                    ),
                  ),
                ),
              )
            else
              Text(
                'Only tide extremes are supplied for this day. No continuous tide curve is inferred.',
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            if (events.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: events
                    .map(
                      (event) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: colors.dark
                              ? colors.softSurface
                              : const Color(0xFFF2F7F5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: colors.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${event.label} · ${event.localTime}',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                                color: colors.ink,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _value(event.heightM, 'm'),
                              style: TextStyle(
                                color: colors.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
          const SizedBox(height: 14),
          Text(
            'Source: ${tide.source}${tide.timezone == null ? '' : ' · ${tide.timezone}'}. ${tide.datum == null ? 'Height datum was not supplied; do not compare these heights with another source.' : 'Tide heights are relative to ${tide.datum}.'} Nearby beach conditions may differ.',
            style: TextStyle(color: colors.muted, fontSize: 11, height: 1.6),
          ),
          if (tide.fetchedAt != null) ...[
            const SizedBox(height: 5),
            Text(
              'Tide predictions fetched ${DateFormat('d MMM, HH:mm').format(tide.fetchedAt!.toUtc())} UTC.',
              style: TextStyle(color: colors.muted, fontSize: 11, height: 1.6),
            ),
          ],
        ],
      ),
    );
  }
}

(String, String) _sampleLocal(String value, DetailedForecastModel forecast) {
  final instant = DateTime.tryParse(value)?.toUtc();
  if (instant == null) return ('', '');
  // The server's hourly wall-clock labels preserve IANA/DST conversion. Use
  // the preceding hour's actual offset rather than the viewer's timezone.
  HourlyForecastModel? reference;
  DateTime? referenceInstant;
  for (final hour in forecast.hours) {
    final time = DateTime.tryParse(hour.time)?.toUtc();
    if (time != null &&
        !time.isAfter(instant) &&
        (referenceInstant == null || time.isAfter(referenceInstant))) {
      reference = hour;
      referenceInstant = time;
    }
  }
  DateTime local;
  if (reference != null && referenceInstant != null) {
    final wall = DateTime.tryParse(
      '${reference.localDate}T${reference.localTime}:00Z',
    );
    local = wall == null
        ? instant.add(Duration(seconds: forecast.utcOffsetSeconds ?? 0))
        : instant.add(wall.difference(referenceInstant));
  } else {
    local = instant.add(Duration(seconds: forecast.utcOffsetSeconds ?? 0));
  }
  return (
    DateFormat('yyyy-MM-dd').format(local),
    DateFormat('HH:mm').format(local),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.color});
  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 18 : 24),
    decoration: BoxDecoration(
      color: color ?? _ForecastColors.of(context).panel,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: _ForecastColors.of(context).border),
    ),
    child: child,
  );
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      color: _ForecastColors.of(context).teal,
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.8,
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

class _IconLabel extends StatelessWidget {
  const _IconLabel({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 15, color: _ForecastColors.of(context).muted),
      const SizedBox(width: 5),
      Flexible(
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: _ForecastColors.of(context).muted,
          ),
        ),
      ),
    ],
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.title, this.subtitle);
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: TextStyle(
          color: _ForecastColors.of(context).ink,
          fontSize: 18,
          fontWeight: FontWeight.w800,
          letterSpacing: -.4,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        subtitle,
        style: TextStyle(
          color: _ForecastColors.of(context).muted,
          fontSize: 12,
        ),
      ),
    ],
  );
}

class _Metric extends StatelessWidget {
  const _Metric({
    super.key,
    required this.width,
    required this.label,
    required this.value,
    required this.detail,
    required this.color,
  });
  final double width;
  final String label;
  final String value;
  final String detail;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: width,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .055),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: _ForecastColors.of(context).muted,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: .5,
          ),
        ),
        const SizedBox(height: 9),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 27,
            fontWeight: FontWeight.w800,
            letterSpacing: -.8,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          detail,
          style: TextStyle(
            fontSize: 11,
            color: _ForecastColors.of(context).muted,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}

class _Component extends StatelessWidget {
  const _Component({
    required this.width,
    required this.title,
    required this.color,
    required this.height,
    required this.period,
    required this.direction,
    required this.note,
  });
  final double width;
  final String title;
  final Color color;
  final double? height;
  final double? period;
  final double? direction;
  final String note;
  @override
  Widget build(BuildContext context) => Container(
    width: width,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .045),
      border: Border.all(color: _ForecastColors.of(context).border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: _ForecastColors.of(context).ink,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 15),
        Text(
          '${_value(height, 'm')}  @  ${_value(period, 's')}',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: color,
            fontSize: 19,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (direction != null && direction!.isFinite) ...[
              Transform.rotate(
                angle: direction! * math.pi / 180,
                child: Icon(Icons.navigation_outlined, color: color, size: 18),
              ),
              const SizedBox(width: 7),
            ],
            Expanded(
              child: Text(
                _direction(direction),
                style: TextStyle(
                  fontSize: 12,
                  color: _ForecastColors.of(context).ink,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          note,
          style: TextStyle(
            color: _ForecastColors.of(context).muted,
            fontSize: 11,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}

class _Series {
  const _Series(this.name, this.color, this.values);
  final String name;
  final Color color;
  final List<double?> values;
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.subtitle,
    required this.chartKey,
    required this.hours,
    required this.series,
    required this.selected,
    required this.onSelected,
    required this.unit,
  });
  final String title;
  final String subtitle;
  final Key chartKey;
  final List<HourlyForecastModel> hours;
  final List<_Series> series;
  final int selected;
  final ValueChanged<int> onSelected;
  final String unit;

  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeading(title, subtitle),
        const SizedBox(height: 16),
        Wrap(
          spacing: 15,
          runSpacing: 8,
          children: series
              .map(
                (item) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 15, height: 3, color: item.color),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${item.name} ${_value(item.values[selected], unit)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: _ForecastColors.of(context).muted,
                        ),
                      ),
                    ),
                  ],
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 12),
        if (series.every(
          (item) =>
              item.values.every((value) => value == null || !value.isFinite),
        ))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Text(
              'No model values supplied for this chart.',
              style: TextStyle(color: _ForecastColors.of(context).muted),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) => Semantics(
              label:
                  '$title in $unit. Selected ${hours[selected].localTime}. ${series.map((item) => '${item.name} ${_value(item.values[selected], unit)}').join(', ')}. Missing values remain gaps.',
              child: GestureDetector(
                key: chartKey,
                behavior: HitTestBehavior.opaque,
                onTapDown: (event) => onSelected(
                  (((event.localPosition.dx - 44) /
                              math.max(1, constraints.maxWidth - 58)) *
                          (hours.length - 1))
                      .round()
                      .clamp(0, hours.length - 1),
                ),
                child: SizedBox(
                  height: 230,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _ForecastPainter(
                      series: series,
                      labels: hours.map((hour) => hour.localTime).toList(),
                      selected: selected,
                      unit: unit,
                      textScaler: MediaQuery.textScalerOf(context),
                      colors: _ForecastColors.of(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 3),
        Text(
          'Tap the chart or use the hour arrows to inspect. Gaps mean unavailable data.',
          style: TextStyle(
            color: _ForecastColors.of(context).muted,
            fontSize: 10,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}

class _ForecastPainter extends CustomPainter {
  const _ForecastPainter({
    required this.series,
    required this.labels,
    required this.selected,
    required this.unit,
    required this.textScaler,
    required this.colors,
  });
  final List<_Series> series;
  final List<String> labels;
  final int selected;
  final String unit;
  final TextScaler textScaler;
  final _ForecastColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(44, 15, size.width - 14, size.height - 38);
    final values = series
        .expand((item) => item.values)
        .whereType<double>()
        .where((value) => value.isFinite);
    final maximum = values.isEmpty
        ? 1.0
        : math.max(1.0, values.reduce(math.max) * 1.15);
    _grid(canvas, plot, 0, maximum, unit, textScaler, colors);
    double x(int index) =>
        plot.left + plot.width * index / math.max(1, labels.length - 1);
    double y(double value) => plot.bottom - (value / maximum) * plot.height;
    final highlight = Paint()..color = colors.teal.withValues(alpha: .07);
    canvas.drawRect(
      Rect.fromLTRB(x(selected) - 7, plot.top, x(selected) + 7, plot.bottom),
      highlight,
    );
    canvas.drawLine(
      Offset(x(selected), plot.top),
      Offset(x(selected), plot.bottom),
      Paint()
        ..color = colors.teal.withValues(alpha: .28)
        ..strokeWidth = 1,
    );
    canvas.save();
    canvas.clipRect(plot.inflate(4));
    for (final item in series) {
      var path = Path();
      var connected = false;
      for (var index = 0; index < item.values.length; index++) {
        final value = item.values[index];
        if (value == null || !value.isFinite) {
          connected = false;
          continue;
        }
        final point = Offset(x(index), y(value));
        if (connected) {
          path.lineTo(point.dx, point.dy);
        } else {
          path.moveTo(point.dx, point.dy);
        }
        connected = true;
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = item.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      final value = item.values[selected];
      if (value != null && value.isFinite) {
        canvas.drawCircle(
          Offset(x(selected), y(value)),
          4.5,
          Paint()..color = colors.panel,
        );
        canvas.drawCircle(
          Offset(x(selected), y(value)),
          3,
          Paint()..color = item.color,
        );
      }
    }
    canvas.restore();
    final indices = {
      0,
      (labels.length / 4).floor(),
      (labels.length / 2).floor(),
      (labels.length * 3 / 4).floor(),
      labels.length - 1,
    };
    for (final index in indices) {
      _paintText(
        canvas,
        labels[index],
        Offset(x(index), plot.bottom + 14),
        textScaler,
        colors.muted,
        centered: true,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ForecastPainter oldDelegate) => true;
}

class _TidePoint {
  const _TidePoint(this.time, this.height, this.label);
  final DateTime time;
  final double height;
  final String label;
}

class _TidePainter extends CustomPainter {
  const _TidePainter(
    this.samples, {
    required this.textScaler,
    required this.colors,
  });
  final List<_TidePoint> samples;
  final TextScaler textScaler;
  final _ForecastColors colors;
  @override
  void paint(Canvas canvas, Size size) {
    final finite = samples.where((sample) => sample.height.isFinite).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    if (finite.length < 2) return;
    final minimum = finite.map((sample) => sample.height).reduce(math.min);
    final maximum = finite.map((sample) => sample.height).reduce(math.max);
    final padding = math.max(.1, (maximum - minimum) * .15);
    final bottom = minimum - padding;
    final top = maximum + padding;
    final plot = Rect.fromLTRB(44, 15, size.width - 14, size.height - 38);
    _grid(canvas, plot, bottom, top, 'm', textScaler, colors);
    final start = finite.first.time.millisecondsSinceEpoch;
    final span = math.max(1, finite.last.time.millisecondsSinceEpoch - start);
    double x(_TidePoint point) =>
        plot.left +
        (point.time.millisecondsSinceEpoch - start) / span * plot.width;
    double y(_TidePoint point) =>
        plot.bottom - (point.height - bottom) / (top - bottom) * plot.height;
    final path = Path();
    for (var i = 0; i < finite.length; i++) {
      final point = finite[i];
      if (i == 0 || point.time.difference(finite[i - 1].time).inMinutes > 35) {
        path.moveTo(x(point), y(point));
      } else {
        path.lineTo(x(point), y(point));
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colors.ocean
        ..strokeWidth = 2.6
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
    for (final index in {
      0,
      (finite.length / 3).floor(),
      (finite.length * 2 / 3).floor(),
      finite.length - 1,
    }) {
      _paintText(
        canvas,
        finite[index].label,
        Offset(x(finite[index]), plot.bottom + 14),
        textScaler,
        colors.muted,
        centered: true,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TidePainter oldDelegate) => true;
}

void _grid(
  Canvas canvas,
  Rect plot,
  double minimum,
  double maximum,
  String unit,
  TextScaler textScaler,
  _ForecastColors colors,
) {
  for (var i = 0; i <= 3; i++) {
    final fraction = i / 3;
    final y = plot.bottom - plot.height * fraction;
    canvas.drawLine(
      Offset(plot.left, y),
      Offset(plot.right, y),
      Paint()
        ..color = colors.border
        ..strokeWidth = 1,
    );
    final value = minimum + (maximum - minimum) * fraction;
    _paintText(
      canvas,
      value.toStringAsFixed(unit == 'kt' ? 0 : 1),
      Offset(plot.left - 8, y - 6),
      textScaler,
      colors.muted,
      right: true,
    );
  }
}

void _paintText(
  Canvas canvas,
  String text,
  Offset at,
  TextScaler scaler,
  Color color, {
  bool centered = false,
  bool right = false,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: 10),
    ),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  painter.paint(
    canvas,
    Offset(
      at.dx -
          (centered
              ? painter.width / 2
              : right
              ? painter.width
              : 0),
      at.dy,
    ),
  );
}

String _dateLabel(String day) {
  final parsed = DateTime.tryParse(day);
  return parsed == null ? day : DateFormat('EEE d MMM').format(parsed);
}

String _localClock(String? value) {
  if (value == null) return '—';
  final match = RegExp(r'T(\d{2}:\d{2})').firstMatch(value);
  return match?.group(1) ?? value;
}

String _range(Iterable<double?> items) {
  final values = items
      .whereType<double>()
      .where((item) => item.isFinite)
      .toList();
  if (values.isEmpty) return '—';
  final min = values.reduce(math.min);
  final max = values.reduce(math.max);
  return (max - min).abs() < .05
      ? min.toStringAsFixed(1)
      : '${min.toStringAsFixed(1)}–${max.toStringAsFixed(1)}';
}

String _value(double? value, String unit, {int digits = 1}) =>
    value == null || !value.isFinite
    ? '—'
    : '${value.toStringAsFixed(digits)} $unit';

String _direction(double? degrees) {
  if (degrees == null || !degrees.isFinite) return 'Direction unavailable';
  final normalized = (degrees % 360 + 360) % 360;
  const labels = [
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
  final compass = labels[((normalized + 11.25) / 22.5).floor() % 16];
  return 'From $compass · ${normalized.round()}°';
}
