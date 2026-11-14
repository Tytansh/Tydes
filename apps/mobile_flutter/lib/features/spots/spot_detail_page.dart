import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart' show currentTabProvider;
import '../../core/network/api_error_message.dart';
import '../../core/network/api_models.dart';
import '../../core/network/detailed_forecast_models.dart';
import '../../core/network/surf_repository.dart';
import '../alerts/create_alert_sheet.dart';
import '../auth/auth_return_path.dart';
import '../home/home_page.dart';
import '../public_previews/public_link_button.dart';
import '../social/social_feed.dart' show travelFeedSpotsProvider;
import 'pro_forecast_panel.dart';
import 'spot_alert_panel.dart';
import 'spots_page.dart';

const _favoriteAccent = Color(0xFF2AA7A1);
const _ink = Color(0xFF173B40);

final spotDetailProvider = FutureProvider.autoDispose.family<SpotModel, String>(
  (ref, String spotId) {
    final repository = ref.watch(surfRepositoryProvider);
    // Navigation from a loaded feed/map already has this static guide. Do not
    // start a whole catalog request merely to optimize a direct spot link.
    for (final catalog in [spotsProvider, travelFeedSpotsProvider]) {
      if (!ref.exists(catalog)) continue;
      final loaded = ref.read(catalog);
      if (loaded.isLoading || loaded.hasError) continue;
      for (final spot in loaded.valueOrNull ?? const <SpotModel>[]) {
        if (spot.id == spotId) return spot;
      }
    }
    return repository.fetchSpot(spotId);
  },
);

// Retained for callers that invalidate daily forecast cards after billing.
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

final spotDetailedForecastProvider = FutureProvider.autoDispose.family((
  ref,
  String spotId,
) async {
  final repository = ref.watch(surfRepositoryProvider);
  var active = true;
  ref.onDispose(() => active = false);
  final blocked = ref.watch(emailVerificationRequiredTokenProvider);
  final profile = await ref.watch(meProvider.future);
  if (!active) return DetailedForecastModel.unavailable(spotId);
  if (blocked != null) throw EmailVerificationRequiredException();
  if (!profile.canAccessLiveForecast(spotId)) {
    return DetailedForecastModel.unavailable(
      spotId,
      note:
          'Choose this as your free forecast spot, or unlock every break with Premium.',
    );
  }
  try {
    final result = await repository.fetchDetailedForecast(spotId);
    if (active && _retainableHourly(result)) {
      _retainSuccessfulSpotRead(
        ref,
        result.fetchedAt!,
        _hourlyMaximumAge(result),
        utcOffsetSeconds: result.utcOffsetSeconds,
      );
    }
    return _ScopedHourly(result, _viewerScope(profile));
  } catch (error) {
    if (_isForecastAuthorizationFailure(error)) rethrow;
    return DetailedForecastModel.unavailable(
      spotId,
      note: friendlyLoadErrorMessage(error, label: 'the hourly forecast'),
    );
  }
});

final spotTideProvider = FutureProvider.autoDispose.family((
  ref,
  String spotId,
) async {
  final repository = ref.watch(surfRepositoryProvider);
  var active = true;
  ref.onDispose(() => active = false);
  final blocked = ref.watch(emailVerificationRequiredTokenProvider);
  final profile = await ref.watch(meProvider.future);
  if (!active) return TideForecastModel.unavailable(spotId);
  if (blocked != null) throw EmailVerificationRequiredException();
  if (!profile.canAccessLiveForecast(spotId)) {
    return TideForecastModel.unavailable(spotId);
  }
  try {
    final result = await repository.fetchTides(spotId);
    if (active && _retainableTides(result)) {
      _retainSuccessfulSpotRead(
        ref,
        result.fetchedAt!,
        const Duration(hours: 12),
      );
    }
    return _ScopedTides(result, _viewerScope(profile));
  } catch (error) {
    if (_isForecastAuthorizationFailure(error)) rethrow;
    return TideForecastModel(
      spotId: spotId,
      available: false,
      stationName: null,
      stationDistanceKm: null,
      source: 'unavailable',
      events: const [],
      note: friendlyLoadErrorMessage(error, label: 'tide predictions'),
    );
  }
});

// Code-local ownership tags are not API fields. They prevent retained values
// from a previous account/entitlement being painted during a dependency reload.
typedef _ViewerScope = ({
  String id,
  bool premium,
  String? freeSpot,
  bool verified,
});

_ViewerScope _viewerScope(UserProfile profile) => (
  id: profile.id,
  premium: profile.premium,
  freeSpot: profile.freeLiveSpotId,
  verified: profile.emailVerified,
);

class _ScopedHourly extends DetailedForecastModel {
  _ScopedHourly(DetailedForecastModel value, this.viewer)
    : super(
        spotId: value.spotId,
        available: value.available,
        source: value.source,
        marineModel: value.marineModel,
        weatherModel: value.weatherModel,
        timezone: value.timezone,
        utcOffsetSeconds: value.utcOffsetSeconds,
        fetchedAt: value.fetchedAt,
        localDate: value.localDate,
        note: value.note,
        hours: value.hours,
        days: value.days,
      );
  final _ViewerScope viewer;
}

class _ScopedTides extends TideForecastModel {
  _ScopedTides(TideForecastModel value, this.viewer)
    : super(
        spotId: value.spotId,
        available: value.available,
        source: value.source,
        stationName: value.stationName,
        stationDistanceKm: value.stationDistanceKm,
        events: value.events,
        samples: value.samples,
        timezone: value.timezone,
        datum: value.datum,
        fetchedAt: value.fetchedAt,
        note: value.note,
      );
  final _ViewerScope viewer;
}

void _retainSuccessfulSpotRead(
  Ref ref,
  DateTime fetchedAt,
  Duration maximumAge, {
  int? utcOffsetSeconds,
}) {
  final now = DateTime.now().toUtc();
  final remaining = fetchedAt.add(maximumAge).difference(now);
  var duration = remaining < const Duration(minutes: 2)
      ? remaining
      : const Duration(minutes: 2);
  if (utcOffsetSeconds != null) {
    final local = now.add(Duration(seconds: utcOffsetSeconds));
    final nextLocalDay = DateTime.utc(
      local.year,
      local.month,
      local.day + 1,
    ).subtract(Duration(seconds: utcOffsetSeconds));
    final untilMidnight = nextLocalDay.difference(now);
    if (untilMidnight < duration) duration = untilMidnight;
  }
  if (duration <= Duration.zero) return;
  final link = ref.keepAlive();
  final timer = Timer(duration, link.close);
  ref.onDispose(timer.cancel);
}

bool _freshlyFetched(DateTime? fetchedAt, DateTime now, Duration maximumAge) =>
    fetchedAt != null &&
    !fetchedAt.isAfter(now.add(const Duration(minutes: 1))) &&
    !fetchedAt.isBefore(now.subtract(maximumAge));

bool _finiteHeight(double? value) =>
    value != null && value.isFinite && value >= 0;

bool _nearFuture(String time, DateTime now, Duration before, Duration after) {
  final instant = DateTime.tryParse(time);
  return instant != null &&
      !instant.isBefore(now.subtract(before)) &&
      !instant.isAfter(now.add(after));
}

bool _retainableHourly(DetailedForecastModel value) {
  final now = DateTime.now().toUtc();
  return value.available &&
      value.source != 'unavailable' &&
      _freshlyFetched(value.fetchedAt, now, _hourlyMaximumAge(value)) &&
      value.hours.any(
        (hour) =>
            _nearFuture(
              hour.time,
              now,
              const Duration(hours: 1),
              const Duration(hours: 2),
            ) &&
            (_finiteHeight(hour.waveHeightM) ||
                _finiteHeight(hour.swellHeightM)),
      );
}

Duration _hourlyMaximumAge(DetailedForecastModel value) =>
    value.weatherModel == 'Temporarily unavailable'
    ? const Duration(minutes: 1)
    : const Duration(hours: 3);

bool _retainableTides(TideForecastModel value) {
  final now = DateTime.now().toUtc();
  return value.available &&
      value.source != 'unavailable' &&
      _freshlyFetched(value.fetchedAt, now, const Duration(hours: 12)) &&
      (value.samples.any(
            (sample) =>
                sample.heightM.isFinite &&
                _nearFuture(
                  sample.time,
                  now,
                  const Duration(hours: 1),
                  const Duration(hours: 2),
                ),
          ) ||
          value.events.any(
            (event) =>
                event.heightM?.isFinite == true &&
                _nearFuture(
                  event.time,
                  now,
                  Duration.zero,
                  const Duration(hours: 26),
                ),
          ));
}

bool _isForecastAuthorizationFailure(Object error) =>
    isEmailVerificationRequired(error) ||
    (error is DioException &&
        (error.response?.statusCode == 401 ||
            error.response?.statusCode == 403));

// Existing invalidation API remains available. The forecast desk intentionally
// does not fetch or display the former heuristic "Best Time" quality score.
final spotSurfWindowProvider = FutureProvider.autoDispose.family((
  ref,
  String spotId,
) {
  return ref.watch(surfRepositoryProvider).fetchSurfWindow(spotId);
});

final unlockingLiveSpotProvider = StateProvider.family<bool, String>(
  (ref, spotId) => false,
);

final spotDetailBundleProvider = FutureProvider.autoDispose.family((
  ref,
  String spotId,
) async {
  final results = await Future.wait<Object>([
    ref.watch(spotDetailProvider(spotId).future),
    ref.watch(spotDetailedForecastProvider(spotId).future),
    ref.watch(spotTideProvider(spotId).future),
  ]);
  return _SpotDetailBundle(
    spot: results[0] as SpotModel,
    forecast: results[1] as DetailedForecastModel,
    tide: results[2] as TideForecastModel,
  );
});

class _SpotDetailBundle {
  const _SpotDetailBundle({
    required this.spot,
    required this.forecast,
    required this.tide,
  });
  final SpotModel spot;
  final DetailedForecastModel forecast;
  final TideForecastModel tide;
}

class SpotDetailPage extends ConsumerWidget {
  const SpotDetailPage({super.key, required this.spotId});
  final String spotId;

  void _refresh(WidgetRef ref) {
    ref.invalidate(spotDetailedForecastProvider(spotId));
    ref.invalidate(spotTideProvider(spotId));
    ref.invalidate(spotDetailBundleProvider(spotId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Hourly and tide sources are independent. A slow/unavailable source must
    // not hold the spot guide or the other source behind a shared Future.wait.
    final detail = ref.watch(spotDetailProvider(spotId));
    final hourly = ref.watch(spotDetailedForecastProvider(spotId));
    final tides = ref.watch(spotTideProvider(spotId));
    final me = ref.watch(meProvider);
    final verificationRequired =
        ref.watch(emailVerificationRequiredTokenProvider) != null;
    final favorites = ref.watch(favoriteSpotIdsProvider);
    final profile = me.valueOrNull;
    final scope = profile == null ? null : _viewerScope(profile);
    final hourlyValue = hourly.valueOrNull;
    final tideValue = tides.valueOrNull;
    final forecast =
        (hourly.hasError ||
                (hourlyValue is _ScopedHourly && hourlyValue.viewer != scope)
            ? null
            : hourlyValue) ??
        DetailedForecastModel.unavailable(
          spotId,
          note: hourly.hasError
              ? friendlyLoadErrorMessage(
                  hourly.error!,
                  label: 'the hourly forecast',
                )
              : null,
        );
    final tide =
        (tides.hasError ||
                (tideValue is _ScopedTides && tideValue.viewer != scope)
            ? null
            : tideValue) ??
        TideForecastModel.unavailable(spotId);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to TYDES',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        ),
        title: const Text('Surf forecast'),
        actions: [
          CopyPublicLinkButton(url: publicSpotLink(spotId)),
          IconButton(
            tooltip: 'Open on map',
            onPressed: () => context.push('/spots-map?spotId=$spotId'),
            icon: const Icon(Icons.map_outlined),
          ),
          IconButton(
            tooltip: favorites.contains(spotId) ? 'Unsave spot' : 'Save spot',
            onPressed: () =>
                ref.read(favoriteSpotIdsProvider.notifier).toggle(spotId),
            icon: Icon(
              favorites.contains(spotId)
                  ? Icons.favorite
                  : Icons.favorite_border,
              color: favorites.contains(spotId) ? _favoriteAccent : null,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: detail.when(
        data: (spot) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1280),
            child: ListView(
              key: PageStorageKey('forecast-desk-$spotId'),
              padding: EdgeInsets.all(
                MediaQuery.sizeOf(context).width < 600 ? 12 : 24,
              ),
              children: [
                _SpotHero(spot: spot),
                const SizedBox(height: 16),
                if (profile != null)
                  SpotAlertPanel(
                    spotId: spotId,
                    onManage: () {
                      ref.read(currentTabProvider.notifier).state = 3;
                      context.go('/');
                    },
                  ),
                if (profile != null && !profile.premium) ...[
                  _ForecastUnlockCard(
                    profile: profile,
                    spotId: spotId,
                    onUnlocked: () {
                      ref.invalidate(meProvider);
                      ref.invalidate(dashboardProvider);
                      ref.invalidate(spotForecastsBySpotProvider);
                      ref.invalidate(spotCardForecastProvider(spotId));
                      ref.invalidate(spotForecastProvider(spotId));
                      ref.invalidate(spotSurfWindowProvider(spotId));
                      _refresh(ref);
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                if (!me.hasError &&
                    !verificationRequired &&
                    profile?.canAccessLiveForecast(spotId) == true) ...[
                  ProForecastPanel(
                    key: ValueKey('forecast-${profile!.id}-$spotId'),
                    forecast: forecast,
                    tide: tide,
                    forecastLoading: hourly.isLoading && !forecast.available,
                    tideLoading: tides.isLoading && !tide.available,
                  ),
                  if ((!hourly.isLoading &&
                          (!forecast.available || forecast.hours.isEmpty)) ||
                      (!tides.isLoading && !tide.available)) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          if (!hourly.isLoading &&
                              (!forecast.available || forecast.hours.isEmpty))
                            OutlinedButton.icon(
                              onPressed: () => ref.invalidate(
                                spotDetailedForecastProvider(spotId),
                              ),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry forecast'),
                            ),
                          if (!tides.isLoading && !tide.available)
                            OutlinedButton.icon(
                              onPressed: () =>
                                  ref.invalidate(spotTideProvider(spotId)),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry tides'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 18),
                _SpotGuide(spot: spot),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off_outlined,
                  color: Theme.of(context).colorScheme.onSurface,
                  size: 32,
                ),
                const SizedBox(height: 12),
                Text(
                  friendlyLoadErrorMessage(error, label: 'spot details'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: () {
                    ref.invalidate(spotDetailProvider(spotId));
                    ref.invalidate(meProvider);
                    _refresh(ref);
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SpotHero extends StatelessWidget {
  const _SpotHero({required this.spot});
  final SpotModel spot;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 22 : 30),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF0D5365), Color(0xFF079F9D)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'TYDES  /  SURF OUTLOOK',
          style: TextStyle(
            color: Color(0xFFB8E6E2),
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          spot.name,
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            letterSpacing: -.8,
          ),
        ),
        const SizedBox(height: 9),
        Text(
          '${spot.area} · ${spot.region} · ${spot.country}',
          style: const TextStyle(
            color: Color(0xFFD5EFEC),
            fontSize: 14,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => CreateAlertSheet(spots: [spot]),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE4F7F3),
                foregroundColor: _ink,
              ),
              icon: const Icon(Icons.add_alert_outlined, size: 18),
              label: const Text('Create alert'),
            ),
            const Text(
              'Model forecasts, not beach observations',
              style: TextStyle(color: Color(0xFFCEEEEA), fontSize: 11),
            ),
          ],
        ),
      ],
    ),
  );
}

class _SpotGuide extends StatelessWidget {
  const _SpotGuide({required this.spot});
  final SpotModel spot;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'BREAK GUIDE',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          spot.summary,
          style: TextStyle(
            fontSize: 15,
            color: Theme.of(context).colorScheme.onSurface,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text('Typical level: ${_difficulty(spot.difficulty)}')),
            if (spot.bestMonths.isNotEmpty)
              Chip(
                label: Text('Typical season: ${spot.bestMonths.join(', ')}'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFFE8BC76)
                  : const Color(0xFF987233),
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Local reef, currents, swell exposure and tide can change conditions dramatically. Check hazards and the beach before paddling out. This guide is not a current safety assessment.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _ForecastUnlockCard extends ConsumerWidget {
  const _ForecastUnlockCard({
    required this.profile,
    required this.spotId,
    required this.onUnlocked,
  });
  final UserProfile profile;
  final String spotId;
  final VoidCallback onUnlocked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final unlocked = profile.freeLiveSpotId == spotId;
    final remaining = profile.freeLiveSpotChangeRemaining(DateTime.now());
    final canSelect = !unlocked && remaining == null;
    final saving = ref.watch(unlockingLiveSpotProvider(spotId));

    Future<void> selectSpot() async {
      final savingState = ref.read(unlockingLiveSpotProvider(spotId).notifier);
      savingState.state = true;
      try {
        await ref.read(surfRepositoryProvider).setFreeLiveSpot(spotId);
        if (context.mounted) onUnlocked();
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                friendlyErrorMessage(
                  error,
                  fallback:
                      'Could not select this forecast spot. Please try again.',
                ),
              ),
            ),
          );
        }
      } finally {
        savingState.state = false;
      }
    }

    return Container(
      key: const ValueKey('forecast-unlock-card'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: dark
            ? theme.colorScheme.surfaceContainerHigh
            : unlocked
            ? const Color(0xFFE4F3EC)
            : const Color(0xFFF1F2E9),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: dark
              ? theme.colorScheme.outlineVariant
              : const Color(0xFFCFDFD6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            unlocked
                ? 'Your free forecast spot'
                : 'One break free. Every break with Premium.',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 18,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            unlocked
                ? 'Explore the full hourly desk here. Premium lets you compare conditions at every mapped break, without changing your free spot.'
                : remaining != null
                ? 'Your free spot is already selected. You can switch in ${_cooldown(remaining)}. Premium opens the hourly forecast desk at every break.'
                : 'Choose this as your free spot for hourly wave, swell and wind model forecasts, plus available tide predictions. You can switch your free spot once every 24 hours.',
            style: TextStyle(
              color: dark
                  ? theme.colorScheme.onSurfaceVariant
                  : const Color(0xFF526B65),
              fontSize: 13,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 15),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (!unlocked)
                FilledButton.icon(
                  key: const ValueKey('select-free-forecast-spot'),
                  onPressed: canSelect && !saving ? selectSpot : null,
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.waves_outlined, size: 18),
                  label: Text(
                    saving
                        ? 'Selecting…'
                        : profile.freeLiveSpotId == null
                        ? 'Use my free spot here'
                        : 'Switch my free spot here',
                  ),
                ),
              OutlinedButton.icon(
                onPressed: () => context.push('/paywall'),
                icon: const Icon(Icons.workspace_premium_outlined, size: 18),
                label: const Text('Explore Premium'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _difficulty(String value) => switch (value) {
  'beginner' => 'Beginner',
  'advanced' => 'Advanced',
  _ => 'Intermediate',
};

String _cooldown(Duration value) {
  final minutes = value.inMinutes < 1 ? 1 : value.inMinutes;
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return hours == 0
      ? '${minutes}m'
      : remainder == 0
      ? '${hours}h'
      : '${hours}h ${remainder}m';
}
