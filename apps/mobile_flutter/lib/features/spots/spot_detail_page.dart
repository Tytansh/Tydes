import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../alerts/create_alert_sheet.dart';
import '../home/home_page.dart';
import 'spots_page.dart';

const _favoriteAccent = Color(0xFF2AA7A1);
const _surfSafetyDisclaimer =
    'Check local hazards and tide before paddling out.';

final spotDetailProvider = FutureProvider.autoDispose.family((
  ref,
  String spotId,
) {
  return ref.watch(surfRepositoryProvider).fetchSpot(spotId);
});

final spotForecastProvider = FutureProvider.autoDispose.family((
  ref,
  String spotId,
) async {
  final forecasts = await ref
      .watch(surfRepositoryProvider)
      .fetchForecasts(spotId: spotId);
  ref.invalidate(spotCardForecastProvider(spotId));
  return forecasts;
});

final spotTideProvider = FutureProvider.autoDispose.family((
  ref,
  String spotId,
) {
  return ref.watch(surfRepositoryProvider).fetchTides(spotId);
});

final spotSurfWindowProvider = FutureProvider.autoDispose.family((
  ref,
  String spotId,
) {
  return ref.watch(surfRepositoryProvider).fetchSurfWindow(spotId);
});

final unlockingLiveSpotProvider = StateProvider.family<bool, String>((
  ref,
  spotId,
) {
  return false;
});

final spotDetailBundleProvider = FutureProvider.autoDispose.family((
  ref,
  String spotId,
) async {
  final repository = ref.watch(surfRepositoryProvider);
  final results = await Future.wait<Object>([
    repository.fetchSpot(spotId),
    ref.watch(spotForecastProvider(spotId).future),
    repository.fetchTides(spotId),
  ]);
  return _SpotDetailBundle(
    spot: results[0] as SpotModel,
    forecasts: results[1] as List<ForecastModel>,
    tide: results[2] as TideForecastModel,
  );
});

class _SpotDetailBundle {
  const _SpotDetailBundle({
    required this.spot,
    required this.forecasts,
    required this.tide,
  });

  final SpotModel spot;
  final List<ForecastModel> forecasts;
  final TideForecastModel tide;
}

class SpotDetailPage extends ConsumerWidget {
  const SpotDetailPage({super.key, required this.spotId});

  final String spotId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(spotDetailBundleProvider(spotId));
    final me = ref.watch(meProvider);
    final favoriteSpotIds = ref.watch(favoriteSpotIdsProvider);
    final surfWindow = ref.watch(spotSurfWindowProvider(spotId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Spot detail'),
        actions: [
          IconButton(
            onPressed: () => context.push('/spots-map?spotId=$spotId'),
            icon: const Icon(Icons.map_outlined),
            tooltip: 'Open on map',
          ),
          IconButton(
            onPressed: () =>
                ref.read(favoriteSpotIdsProvider.notifier).toggle(spotId),
            icon: Icon(
              favoriteSpotIds.contains(spotId)
                  ? Icons.favorite
                  : Icons.favorite_border,
              color: favoriteSpotIds.contains(spotId) ? _favoriteAccent : null,
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: detail.when(
          data: (bundle) {
            final item = bundle.spot;
            final forecastRows = bundle.forecasts;
            final currentForecast = forecastRows.isEmpty
                ? null
                : forecastRows.first;
            final waveValue =
                currentForecast?.waveDisplay ?? '${item.waveHeightM}m';
            final waveLevelValue = _waveLevelLabel(
              currentForecast?.waveLevel ?? item.waveLevel,
            );
            final waterValue = currentForecast?.seaSurfaceTemperatureC != null
                ? '${currentForecast!.seaSurfaceTemperatureC!.toStringAsFixed(1)}C'
                : '${item.waterTempC}C';

            return ListView(
              children: [
                Text(
                  item.name,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text('${item.area}, ${item.region}, ${item.country}'),
                const SizedBox(height: 14),
                Text(item.summary),
                const SizedBox(height: 12),
                const _SurfSafetyDisclaimer(),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _StatChip(label: 'Wave level', value: waveLevelValue),
                    _StatChip(label: 'Wave', value: waveValue),
                    _StatChip(label: 'Water', value: waterValue),
                  ],
                ),
                const SizedBox(height: 16),
                me.when(
                  data: (profile) => _LiveDataUnlockCard(
                    profile: profile,
                    spotId: spotId,
                    onUnlocked: () {
                      ref.invalidate(meProvider);
                      ref.invalidate(dashboardProvider);
                      ref.invalidate(spotForecastsBySpotProvider);
                      ref.invalidate(spotCardForecastProvider(spotId));
                      ref.invalidate(spotForecastProvider(spotId));
                      ref.invalidate(spotSurfWindowProvider(spotId));
                      ref.invalidate(spotDetailBundleProvider(spotId));
                    },
                  ),
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (context) => CreateAlertSheet(spots: [item]),
                  ),
                  icon: const Icon(Icons.add_alert_outlined),
                  label: const Text('Create alert'),
                ),
                const SizedBox(height: 24),
                _TideCard(tide: bundle.tide),
                const SizedBox(height: 24),
                _BestSurfWindowCard(window: surfWindow),
                const SizedBox(height: 24),
                Text(
                  'Forecast window',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                me.when(
                  data: (profile) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!profile.canAccessLiveForecast(spotId) &&
                          profile.freeLiveSpotId != null)
                        const _UpgradeCard(
                          title: 'Premium subscription',
                          body:
                              'Your one free live-data unlock is already used. Upgrade to unlock live forecast and tide data on every spot.',
                        ),
                      ...bundle.forecasts.map((row) => _ForecastCard(row: row)),
                    ],
                  ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => Column(
                    children: bundle.forecasts
                        .map((row) => _ForecastCard(row: row))
                        .toList(),
                  ),
                ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) =>
              Center(child: Text('Could not load spot details: $error')),
        ),
      ),
    );
  }
}

class _ForecastCard extends StatelessWidget {
  const _ForecastCard({required this.row});

  final ForecastModel row;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(row.day, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: row.isLive
                        ? const Color(0xFFDDF5EA)
                        : const Color(0xFFEDE8DA),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    row.isLive ? 'Live' : 'Estimated',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _ForecastSummary(row: row),
            const SizedBox(height: 12),
            Text(
              _qualityLabel(row.waveLevel),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            _ForecastDetails(row: row),
            if (row.confidenceNote != null) ...[
              const SizedBox(height: 8),
              Text(
                row.confidenceNote!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BestSurfWindowCard extends StatelessWidget {
  const _BestSurfWindowCard({required this.window});

  final AsyncValue<SurfWindowModel> window;

  @override
  Widget build(BuildContext context) {
    return window.when(
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (_, _) => const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Best Time Today is unavailable right now.'),
        ),
      ),
      data: (data) {
        if (!data.available) {
          return Card(
            color: const Color(0xFFFFF4E4),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(data.note ?? 'Premium unlocks Best Time Today.'),
            ),
          );
        }
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Best Time Today',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    _WindowRatingChip(rating: data.rating),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${data.bestStartLabel} - ${data.bestEndLabel}',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (data.summary != null) ...[
                  const SizedBox(height: 8),
                  Text(data.summary!),
                ],
                const SizedBox(height: 14),
                _HourlySurfGraph(hours: data.hours),
                if (data.note != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    data.note!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SurfSafetyDisclaimer extends StatelessWidget {
  const _SurfSafetyDisclaimer();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E4),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _surfSafetyDisclaimer,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _HourlySurfGraph extends StatelessWidget {
  const _HourlySurfGraph({required this.hours});

  final List<SurfWindowHourModel> hours;

  @override
  Widget build(BuildContext context) {
    if (hours.isEmpty) return const SizedBox.shrink();
    final maxScore = hours
        .map((hour) => hour.score)
        .reduce((value, next) => value > next ? value : next)
        .clamp(0.1, 1.25);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final hour in hours)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${hour.waveHeightM.toStringAsFixed(1)}m',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 5),
                  Container(
                    width: 24,
                    height: 18 + ((hour.score / maxScore) * 54),
                    decoration: BoxDecoration(
                      color: _windowScoreColor(hour.score),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    hour.label,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _WindowRatingChip extends StatelessWidget {
  const _WindowRatingChip({required this.rating});

  final String rating;

  @override
  Widget build(BuildContext context) {
    final color = _windowRatingColor(rating);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _windowRatingLabel(rating),
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _TideCard extends StatelessWidget {
  const _TideCard({required this.tide});

  final TideForecastModel tide;

  @override
  Widget build(BuildContext context) {
    final groupedEvents = _groupTideEventsByDay(tide.events);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Tides', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                if (tide.available)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDDF5EA),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      'Live',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            if (tide.stationName != null) ...[
              const SizedBox(height: 6),
              Text(
                tide.stationDistanceKm == null
                    ? 'Station: ${tide.stationName}'
                    : 'Station: ${tide.stationName} • ${tide.stationDistanceKm!.toStringAsFixed(1)}km away',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            if (groupedEvents.isEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Tide unavailable'),
                  if (tide.note != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      tide.note!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (
                    var index = 0;
                    index < groupedEvents.length;
                    index++
                  ) ...[
                    Expanded(child: _TideDayGroup(group: groupedEvents[index])),
                    if (index != groupedEvents.length - 1)
                      const SizedBox(width: 16),
                  ],
                ],
              ),
            if (groupedEvents.isNotEmpty && tide.note != null) ...[
              const SizedBox(height: 8),
              Text(
                _safeTideNote(tide),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TideDayGroup extends StatelessWidget {
  const _TideDayGroup({required this.group});

  final _TideDayEvents group;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          group.label,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        ...group.events.map(
          (event) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Flexible(
                  flex: 0,
                  child: Text(
                    event.label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(child: Text(event.localTime)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

List<_TideDayEvents> _groupTideEventsByDay(List<TideEventModel> events) {
  if (events.isEmpty) return const [];

  final sortedEvents = [...events]
    ..sort((a, b) => DateTime.parse(a.time).compareTo(DateTime.parse(b.time)));
  final today = DateTime.now();
  final tomorrow = today.add(const Duration(days: 1));
  final wantedDates = [_dateKey(today), _dateKey(tomorrow)];

  return wantedDates
      .map((dateKey) {
        final eventDate = DateTime.parse(dateKey);
        return _TideDayEvents(
          label: _tideDayLabel(eventDate, today, tomorrow),
          events: sortedEvents
              .where((event) => event.localDate == dateKey)
              .toList(),
        );
      })
      .where((group) => group.events.isNotEmpty)
      .toList();
}

String _tideDayLabel(DateTime date, DateTime today, DateTime tomorrow) {
  if (_sameDay(date, today)) return 'Today';
  if (_sameDay(date, tomorrow)) return 'Tomorrow';
  return '${date.month}/${date.day}';
}

bool _sameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _dateKey(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

class _TideDayEvents {
  const _TideDayEvents({required this.label, required this.events});

  final String label;
  final List<TideEventModel> events;
}

String _safeTideNote(TideForecastModel tide) {
  if (tide.available) {
    return 'Tide times are estimates for surf planning, not navigation.';
  }
  return 'Tide data is unavailable right now.';
}

class _ForecastDetails extends StatelessWidget {
  const _ForecastDetails({required this.row});

  final ForecastModel row;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      dense: true,
      title: const Text('Learn what this means'),
      children: [
        _DetailLine(
          label: 'Wave',
          value: row.waveDisplay,
          help: 'The expected surf height for this day.',
        ),
        if (row.windDisplay != null)
          _DetailLine(
            label: 'Wind',
            value: row.windDisplay!,
            help:
                'Knots are the normal marine wind unit. Lower wind is usually cleaner surf.',
          ),
        if (row.periodS != null)
          _DetailLine(
            label: 'Period',
            value: '${row.periodS}s',
            help:
                'Seconds between swell waves. Higher period usually means more push and power.',
          ),
        if (row.seaSurfaceTemperatureC != null)
          _DetailLine(
            label: 'Water temp',
            value: '${row.seaSurfaceTemperatureC!.toStringAsFixed(1)}C',
            help: 'Approximate sea temperature.',
          ),
      ],
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.label,
    required this.value,
    required this.help,
  });

  final String label;
  final String value;
  final String help;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$label: $value',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 3),
            Text(help, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _ForecastSummary extends StatelessWidget {
  const _ForecastSummary({required this.row});

  final ForecastModel row;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _StatChip(label: 'Wave', value: row.waveDisplay),
        if (row.windDisplay != null)
          _StatChip(label: 'Wind', value: _friendlyWind(row)),
        if (row.seaSurfaceTemperatureC != null)
          _StatChip(
            label: 'Water',
            value: '${row.seaSurfaceTemperatureC!.toStringAsFixed(1)}C',
          ),
        if (row.periodS != null)
          _StatChip(label: 'Power', value: _friendlyPeriod(row.periodS!)),
      ],
    );
  }
}

class _UpgradeCard extends StatelessWidget {
  const _UpgradeCard({
    this.title = 'Access more live forecast data',
    this.body,
  });

  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFF4E4),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              body ??
                  'Free users get one unlocked live forecast spot. Upgrade to unlock live wave, wind, period, and tide data across more breaks.',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => context.push('/paywall'),
              child: const Text('Access more info'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveDataUnlockCard extends ConsumerWidget {
  const _LiveDataUnlockCard({
    required this.profile,
    required this.spotId,
    required this.onUnlocked,
  });

  final UserProfile profile;
  final String spotId;
  final VoidCallback onUnlocked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (profile.premium) {
      return const SizedBox.shrink();
    }

    final isUnlockedSpot = profile.freeLiveSpotId == spotId;
    final hasChosenAnotherSpot =
        profile.freeLiveSpotId != null && !isUnlockedSpot;
    final isSaving = ref.watch(unlockingLiveSpotProvider(spotId));

    Future<void> unlockSpot() async {
      ref.read(unlockingLiveSpotProvider(spotId).notifier).state = true;
      try {
        await ref.read(surfRepositoryProvider).setFreeLiveSpot(spotId);
        onUnlocked();
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error.toString().replaceFirst('Bad state: ', '')),
            ),
          );
        }
      } finally {
        ref.read(unlockingLiveSpotProvider(spotId).notifier).state = false;
      }
    }

    final title = isUnlockedSpot
        ? 'Live data unlocked'
        : hasChosenAnotherSpot
        ? 'Premium subscription'
        : 'Unlock more data';
    final subtitle = isUnlockedSpot
        ? 'This is your free live-data spot for wave, wind, period, and tide updates.'
        : hasChosenAnotherSpot
        ? 'Free users can unlock one location only. Premium unlocks live data on every spot.'
        : 'Free users can unlock one spot for live wave and tide data. Choose carefully.';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isUnlockedSpot
            ? const Color(0xFFDDF5EA)
            : const Color(0xFFF6F2E8),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isUnlockedSpot
              ? const Color(0xFF9CD8B8)
              : const Color(0xFFE4DCCD),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(subtitle),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              IgnorePointer(
                ignoring: isUnlockedSpot || hasChosenAnotherSpot || isSaving,
                child: Switch.adaptive(
                  value: isUnlockedSpot || isSaving,
                  onChanged:
                      (!isUnlockedSpot && !hasChosenAnotherSpot && !isSaving)
                      ? (_) => unlockSpot()
                      : null,
                ),
              ),
            ],
          ),
          if (hasChosenAnotherSpot) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => context.push('/paywall'),
                icon: const Icon(Icons.lock_outline),
                label: const Text('Premium subscription'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _friendlyWind(ForecastModel row) {
  final wind = row.windKts;
  if (wind == null) return row.windDisplay ?? 'Unknown';
  final kmh = (wind * 1.852).toStringAsFixed(1);
  final speed = '${_formatSpeed(wind)}kts / ${kmh}km/h';
  if (wind <= 5) return 'light ($speed)';
  if (wind <= 12) return 'manageable ($speed)';
  if (wind <= 18) return 'windy ($speed)';
  return 'strong ($speed)';
}

String _formatSpeed(double value) {
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toStringAsFixed(1);
}

String _friendlyPeriod(int periodS) {
  if (periodS < 7) return 'weak (${periodS}s)';
  if (periodS < 11) return 'fun (${periodS}s)';
  return 'strong (${periodS}s)';
}

String _qualityLabel(String? waveLevel) {
  if (waveLevel == null) return 'Quality: unavailable';
  return 'Quality: ${_waveLevelLabel(waveLevel)}';
}

String _waveLevelLabel(String waveLevel) {
  return switch (waveLevel) {
    'beginner' => 'Beginner',
    'advanced' => 'Advanced',
    _ => 'Intermediate',
  };
}

String _windowRatingLabel(String rating) {
  return switch (rating) {
    'epic' => 'Epic',
    'good' => 'Good',
    'fair' => 'Fair',
    _ => 'Poor',
  };
}

Color _windowRatingColor(String rating) {
  return switch (rating) {
    'epic' => const Color(0xFF0F8F75),
    'good' => const Color(0xFF2E8FE8),
    'fair' => const Color(0xFFE29A2D),
    _ => const Color(0xFF8A6F63),
  };
}

Color _windowScoreColor(double score) {
  if (score >= 0.95) return const Color(0xFF0F8F75);
  if (score >= 0.78) return const Color(0xFF2E8FE8);
  if (score >= 0.58) return const Color(0xFFE29A2D);
  return const Color(0xFFB8AAA2);
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('$label: $value'),
    );
  }
}
