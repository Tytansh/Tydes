import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error_message.dart';
import '../../core/network/api_models.dart';
import '../../core/network/detailed_forecast_models.dart';
import '../../core/network/surf_repository.dart';
import '../alerts/create_alert_sheet.dart';
import '../auth/auth_return_path.dart';
import '../home/home_page.dart';
import '../public_previews/public_link_button.dart';
import 'pro_forecast_panel.dart';
import 'spots_page.dart';

const _favoriteAccent = Color(0xFF2AA7A1);
const _ink = Color(0xFF173B40);

final spotDetailProvider = FutureProvider.autoDispose.family((
  ref,
  String spotId,
) {
  return ref.watch(surfRepositoryProvider).fetchSpot(spotId);
});

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
  final profile = await ref.watch(meProvider.future);
  if (!profile.canAccessLiveForecast(spotId)) {
    return DetailedForecastModel.unavailable(
      spotId,
      note:
          'Choose this as your free forecast spot, or unlock every break with Premium.',
    );
  }
  try {
    return await repository.fetchDetailedForecast(spotId);
  } catch (error) {
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
  final profile = await ref.watch(meProvider.future);
  if (!profile.canAccessLiveForecast(spotId)) {
    return TideForecastModel.unavailable(spotId);
  }
  return repository.fetchTides(spotId);
});

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
    final detail = ref.watch(spotDetailBundleProvider(spotId));
    final me = ref.watch(meProvider);
    final favorites = ref.watch(favoriteSpotIdsProvider);
    final profile = me.valueOrNull;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to Tydes',
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
        data: (bundle) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1280),
            child: ListView(
              key: PageStorageKey('forecast-desk-$spotId'),
              padding: EdgeInsets.all(
                MediaQuery.sizeOf(context).width < 600 ? 12 : 24,
              ),
              children: [
                _SpotHero(spot: bundle.spot),
                const SizedBox(height: 16),
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
                if (profile?.canAccessLiveForecast(spotId) == true ||
                    bundle.forecast.available) ...[
                  ProForecastPanel(
                    forecast: bundle.forecast,
                    tide: bundle.tide,
                  ),
                  if (!bundle.forecast.available ||
                      bundle.forecast.hours.isEmpty) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => _refresh(ref),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry forecast'),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 18),
                _SpotGuide(spot: bundle.spot),
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
