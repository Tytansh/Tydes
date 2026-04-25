import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';

final spotsProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchSpots(),
);

const _groupByRegionThreshold = 5;

class SpotsPage extends ConsumerWidget {
  const SpotsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spots = ref.watch(spotsProvider);
    final favoriteSpotIds = ref.watch(favoriteSpotIdsProvider);
    final dashboard = ref.watch(dashboardProvider);
    final ads = ref.watch(homeAdsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Surf spots'),
        actions: [
          IconButton(
            onPressed: () => context.push('/spots-map'),
            icon: const Icon(Icons.map_outlined),
            tooltip: 'Map view',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: spots.when(
          data: (items) {
            if (items.isEmpty) {
              return const _EmptySpotsState();
            }

            final favoriteSpots = _sortSpots(
              items.where((spot) => favoriteSpotIds.contains(spot.id)).toList(),
            );

            final countries = _groupBy(items, (spot) => spot.country);
            final orderedCountryNames = _ordered(countries.keys.toList());

            return ListView(
              children: [
                const _SpotsHero(),
                const SizedBox(height: 18),
                dashboard.when(
                  data: (data) => _FeaturedForecastCard(data: data),
                  loading: () => const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
                  error: (_, _) => const SizedBox.shrink(),
                ),
                const SizedBox(height: 18),
                _FavoritesSection(
                  spots: favoriteSpots,
                  favoriteSpotIds: favoriteSpotIds,
                  onFavoritePressed: (spotId) =>
                      ref.read(favoriteSpotIdsProvider.notifier).toggle(spotId),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Countries',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => context.push('/spots-map'),
                      icon: const Icon(Icons.public),
                      label: const Text('Map'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ...orderedCountryNames.map(
                  (country) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _CountrySection(
                      country: country,
                      spots: _sortSpots(countries[country]!),
                      favoriteSpotIds: favoriteSpotIds,
                      onFavoritePressed: (spotId) => ref
                          .read(favoriteSpotIdsProvider.notifier)
                          .toggle(spotId),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _PartnerOffers(ads: ads),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) =>
              Center(child: Text('Could not load spots: $error')),
        ),
      ),
    );
  }

  List<String> _ordered(List<String> items) {
    final next = [...items];
    next.sort();
    return next;
  }

  List<SpotModel> _sortSpots(List<SpotModel> spots) {
    final next = [...spots];
    next.sort((a, b) {
      final country = a.country.compareTo(b.country);
      if (country != 0) return country;
      final region = a.region.compareTo(b.region);
      if (region != 0) return region;
      final area = a.area.compareTo(b.area);
      if (area != 0) return area;
      return a.name.compareTo(b.name);
    });
    return next;
  }

  Map<String, List<SpotModel>> _groupBy(
    List<SpotModel> spots,
    String Function(SpotModel spot) keyOf,
  ) {
    final groups = <String, List<SpotModel>>{};
    for (final spot in spots) {
      groups.putIfAbsent(keyOf(spot), () => []).add(spot);
    }
    return groups;
  }
}

class _SpotsHero extends StatelessWidget {
  const _SpotsHero();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF113D3B), Color(0xFF5AA89A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.waves, color: Colors.white, size: 34),
          const SizedBox(height: 28),
          Text(
            'Find your next paddle out',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(color: Colors.white),
          ),
          const SizedBox(height: 8),
          const Text(
            'Favorites, live forecast cards, map view, and country surf guides now live here.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            onPressed: () => context.push('/spots-map'),
            icon: const Icon(Icons.map_outlined),
            label: const Text('Open map'),
          ),
        ],
      ),
    );
  }
}

class _FeaturedForecastCard extends StatelessWidget {
  const _FeaturedForecastCard({required this.data});

  final DashboardModel data;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => context.push('/spot/${data.featuredSpot.id}'),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: const Color(0xFFD7EFEC),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.bolt_outlined),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Featured now',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    Text(
                      data.featuredSpot.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      '${data.topForecast.waveDisplay} • ${data.topForecast.quality}',
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _PartnerOffers extends StatelessWidget {
  const _PartnerOffers({required this.ads});

  final AsyncValue<List<AdModel>> ads;

  @override
  Widget build(BuildContext context) {
    return ads.when(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Partner offers',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            ...items.map(
              (ad) => Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  title: Text(ad.title),
                  subtitle: Text(ad.partner),
                  trailing: Text(ad.cta),
                ),
              ),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _FavoritesSection extends StatelessWidget {
  const _FavoritesSection({
    required this.spots,
    required this.favoriteSpotIds,
    required this.onFavoritePressed,
  });

  final List<SpotModel> spots;
  final Set<String> favoriteSpotIds;
  final ValueChanged<String> onFavoritePressed;

  @override
  Widget build(BuildContext context) {
    if (spots.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const Icon(Icons.favorite_border),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Favorites will show here once you save a few breaks.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Favorites', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        ...spots.map(
          (spot) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _SpotCard(
              spot: spot,
              isFavorite: favoriteSpotIds.contains(spot.id),
              onFavoritePressed: () => onFavoritePressed(spot.id),
            ),
          ),
        ),
      ],
    );
  }
}

class _CountrySection extends StatelessWidget {
  const _CountrySection({
    required this.country,
    required this.spots,
    required this.favoriteSpotIds,
    required this.onFavoritePressed,
  });

  final String country;
  final List<SpotModel> spots;
  final Set<String> favoriteSpotIds;
  final ValueChanged<String> onFavoritePressed;

  @override
  Widget build(BuildContext context) {
    final shouldGroupByRegion = spots.length > _groupByRegionThreshold;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        title: Text(country, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(
          shouldGroupByRegion
              ? '${spots.length} breaks grouped by area'
              : '${spots.length} beach${spots.length == 1 ? '' : 'es'}',
        ),
        children: shouldGroupByRegion
            ? _regionSections()
            : _spotCards(spots, includeCountry: false),
      ),
    );
  }

  List<Widget> _regionSections() {
    final regions = <String, List<SpotModel>>{};
    for (final spot in spots) {
      regions.putIfAbsent(spot.region, () => []).add(spot);
    }

    final regionNames = regions.keys.toList()..sort();
    return regionNames
        .map(
          (region) => _RegionSection(
            region: region,
            spots: regions[region]!,
            favoriteSpotIds: favoriteSpotIds,
            onFavoritePressed: onFavoritePressed,
          ),
        )
        .toList();
  }

  List<Widget> _spotCards(
    List<SpotModel> items, {
    required bool includeCountry,
  }) {
    return items
        .map(
          (spot) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _SpotCard(
              spot: spot,
              includeCountry: includeCountry,
              isFavorite: favoriteSpotIds.contains(spot.id),
              onFavoritePressed: () => onFavoritePressed(spot.id),
            ),
          ),
        )
        .toList();
  }
}

class _RegionSection extends StatelessWidget {
  const _RegionSection({
    required this.region,
    required this.spots,
    required this.favoriteSpotIds,
    required this.onFavoritePressed,
  });

  final String region;
  final List<SpotModel> spots;
  final Set<String> favoriteSpotIds;
  final ValueChanged<String> onFavoritePressed;

  @override
  Widget build(BuildContext context) {
    final areas = spots.map((spot) => spot.area).toSet().toList()..sort();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF6F3ED),
          borderRadius: BorderRadius.circular(18),
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          title: Text(region),
          subtitle: Text('${spots.length} breaks • ${areas.join(', ')}'),
          children: spots
              .map(
                (spot) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _SpotCard(
                    spot: spot,
                    includeCountry: false,
                    isFavorite: favoriteSpotIds.contains(spot.id),
                    onFavoritePressed: () => onFavoritePressed(spot.id),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _SpotCard extends StatelessWidget {
  const _SpotCard({
    required this.spot,
    required this.isFavorite,
    required this.onFavoritePressed,
    this.includeCountry = true,
  });

  final SpotModel spot;
  final bool isFavorite;
  final VoidCallback onFavoritePressed;
  final bool includeCountry;

  @override
  Widget build(BuildContext context) {
    final location = includeCountry
        ? '${spot.area}, ${spot.region}, ${spot.country}'
        : '${spot.area}, ${spot.region}';

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        title: Row(
          children: [
            Expanded(child: Text(spot.name)),
            _FavoriteButton(
              isFavorite: isFavorite,
              onPressed: onFavoritePressed,
            ),
          ],
        ),
        subtitle: Text('$location\n${spot.summary}'),
        isThreeLine: true,
        trailing: Text('${spot.waveHeightM}m'),
        onTap: () => context.push('/spot/${spot.id}'),
      ),
    );
  }
}

class _FavoriteButton extends StatelessWidget {
  const _FavoriteButton({required this.isFavorite, required this.onPressed});

  final bool isFavorite;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
      icon: Icon(
        isFavorite ? Icons.favorite : Icons.favorite_border,
        color: isFavorite ? const Color(0xFFCF4A3B) : const Color(0xFF81949A),
      ),
      tooltip: isFavorite ? 'Remove favorite' : 'Save favorite',
    );
  }
}

class _EmptySpotsState extends StatelessWidget {
  const _EmptySpotsState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.favorite_border, size: 34),
              const SizedBox(height: 12),
              Text(
                'No spots available',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text('Try again in a moment.', textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
