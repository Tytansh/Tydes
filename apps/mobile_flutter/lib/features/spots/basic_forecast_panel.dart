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
                return Column(
                  children: [
                    for (final day in forecast.days)
                      Padding(
                        key: ValueKey('basic-forecast-day-${day.day}'),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Semantics(
                          label:
                              '${day.day}, daily mean significant wave height ${day.waveHeightM.toStringAsFixed(1)} metres',
                          excludeSemantics: true,
                          child: Row(
                            children: [
                              Expanded(
                                flex: showBars ? 2 : 1,
                                child: Text(
                                  DateFormat(
                                    'EEE, d MMM',
                                  ).format(DateTime.parse(day.day)),
                                  style: TextStyle(
                                    color: ink,
                                    fontWeight: FontWeight.w600,
                                  ),
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
                                      widthFactor: maxHeight == 0
                                          ? 0
                                          : day.waveHeightM / maxHeight,
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
                                          borderRadius: BorderRadius.circular(
                                            99,
                                          ),
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
