import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';

const _favoriteAccent = Color(0xFF2AA7A1);

final spotsProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchSpots(),
);
final spotCardForecastProvider = FutureProvider.autoDispose
    .family<ForecastModel?, String>((ref, spotId) async {
      final forecasts = await ref
          .watch(surfRepositoryProvider)
          .fetchForecasts(spotId);
      if (forecasts.isEmpty) return null;
      return forecasts.first;
    });

const _groupByRegionThreshold = 5;
const _groupWithinRegionThreshold = 8;
const _baliAreaOrder = <String>[
  'Canggu',
  'Bukit / Uluwatu',
  'Kuta / Airport Reefs',
  'Sanur',
  'Keramas / East Bali',
  'Medewi / West Bali',
  'Nusa Lembongan',
];

class SpotsPage extends ConsumerStatefulWidget {
  const SpotsPage({super.key});

  @override
  ConsumerState<SpotsPage> createState() => _SpotsPageState();
}

class _SpotsPageState extends ConsumerState<SpotsPage> {
  final _searchController = TextEditingController();

  String get _searchQuery => _searchController.text.trim();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spots = ref.watch(spotsProvider);
    final favoriteSpotIds = ref.watch(favoriteSpotIdsProvider);
    final ads = ref.watch(homeAdsProvider);
    final me = ref.watch(meProvider);
    final isPremium = me.maybeWhen(
      data: (profile) => profile.premium,
      orElse: () => false,
    );

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

            final filteredItems = _searchQuery.isEmpty
                ? items
                : _sortSpots(
                    items.where((spot) => _matchesSpot(spot, _searchQuery)).toList(),
                  );
            final favoriteSpots = _sortSpots(
              items.where((spot) => favoriteSpotIds.contains(spot.id)).toList(),
            );

            final countries = _groupBy(filteredItems, (spot) => spot.country);
            final orderedCountryNames = _orderedGroupedKeys(countries);

            return ListView(
              children: [
                const _SpotsHero(),
                const SizedBox(height: 18),
                _SpotsSearchBar(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  onCleared: () {
                    _searchController.clear();
                    setState(() {});
                  },
                ),
                const SizedBox(height: 18),
                if (_searchQuery.isEmpty) ...[
                  _FavoritesSection(
                    spots: favoriteSpots,
                    isPremium: isPremium,
                    favoriteSpotIds: favoriteSpotIds,
                    onFavoritePressed: (spotId) => ref
                        .read(favoriteSpotIdsProvider.notifier)
                        .toggle(spotId),
                  ),
                  const SizedBox(height: 18),
                ],
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _searchQuery.isEmpty
                            ? 'Countries'
                            : 'Search results (${filteredItems.length})',
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
                if (filteredItems.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(18),
                      child: Text(
                        'No spots matched that search yet. Try a country, area, or break name.',
                      ),
                    ),
                  )
                else
                  ...orderedCountryNames.map(
                    (country) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _CountrySection(
                        country: country,
                        spots: _sortSpots(countries[country]!),
                        isPremium: isPremium,
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

  bool _matchesSpot(SpotModel spot, String query) {
    final q = query.toLowerCase();
    return spot.name.toLowerCase().contains(q) ||
        spot.area.toLowerCase().contains(q) ||
        spot.region.toLowerCase().contains(q) ||
        spot.country.toLowerCase().contains(q);
  }
}

List<String> _orderedGroupedKeys(Map<String, List<SpotModel>> groups) {
  final next = groups.keys.toList();
  next.sort((a, b) {
    final countCompare = groups[b]!.length.compareTo(groups[a]!.length);
    if (countCompare != 0) return countCompare;
    return a.compareTo(b);
  });
  return next;
}

class _SpotsSearchBar extends StatelessWidget {
  const _SpotsSearchBar({
    required this.controller,
    required this.onChanged,
    required this.onCleared,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onCleared;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search spots, areas, or countries',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                onPressed: onCleared,
                icon: const Icon(Icons.close),
              ),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
      ),
    );
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
    required this.isPremium,
    required this.favoriteSpotIds,
    required this.onFavoritePressed,
  });

  final List<SpotModel> spots;
  final bool isPremium;
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
              isPremium: isPremium,
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
    required this.isPremium,
    required this.favoriteSpotIds,
    required this.onFavoritePressed,
  });

  final String country;
  final List<SpotModel> spots;
  final bool isPremium;
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

    final regionNames = _orderedGroupedKeys(regions);
    return regionNames
        .map(
          (region) => _RegionSection(
            region: region,
            spots: regions[region]!,
            isPremium: isPremium,
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
              isPremium: isPremium,
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
    required this.isPremium,
    required this.favoriteSpotIds,
    required this.onFavoritePressed,
  });

  final String region;
  final List<SpotModel> spots;
  final bool isPremium;
  final Set<String> favoriteSpotIds;
  final ValueChanged<String> onFavoritePressed;

  @override
  Widget build(BuildContext context) {
    if (region == 'Bali') {
      return _BaliRegionSection(
        spots: spots,
        isPremium: isPremium,
        favoriteSpotIds: favoriteSpotIds,
        onFavoritePressed: onFavoritePressed,
      );
    }

    final areaGroups = <String, List<SpotModel>>{};
    for (final spot in spots) {
      areaGroups.putIfAbsent(spot.area, () => []).add(spot);
    }
    final areas = _orderedGroupedKeys(areaGroups);
    final shouldGroupByArea =
        spots.length >= _groupWithinRegionThreshold && areas.length >= 3;

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
          children: shouldGroupByArea ? _areaSections() : _spotCards(),
        ),
      ),
    );
  }

  List<Widget> _areaSections() {
    final groups = <String, List<SpotModel>>{};
    for (final spot in spots) {
      groups.putIfAbsent(spot.area, () => []).add(spot);
    }

    final orderedAreas = _orderedGroupedKeys(groups);
    return orderedAreas
        .map(
          (area) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _AreaSection(
              label: area,
              spots: groups[area]!,
              isPremium: isPremium,
              favoriteSpotIds: favoriteSpotIds,
              onFavoritePressed: onFavoritePressed,
            ),
          ),
        )
        .toList();
  }

  List<Widget> _spotCards() {
    return spots
        .map(
          (spot) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _SpotCard(
              spot: spot,
              isPremium: isPremium,
              includeCountry: false,
              isFavorite: favoriteSpotIds.contains(spot.id),
              onFavoritePressed: () => onFavoritePressed(spot.id),
            ),
          ),
        )
        .toList();
  }
}

class _BaliRegionSection extends StatelessWidget {
  const _BaliRegionSection({
    required this.spots,
    required this.isPremium,
    required this.favoriteSpotIds,
    required this.onFavoritePressed,
  });

  final List<SpotModel> spots;
  final bool isPremium;
  final Set<String> favoriteSpotIds;
  final ValueChanged<String> onFavoritePressed;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<SpotModel>>{};
    for (final spot in spots) {
      final key = _baliAreaForSpot(spot);
      groups.putIfAbsent(key, () => []).add(spot);
    }

    final orderedAreas = groups.keys.toList()
      ..sort((a, b) {
        final countCompare = groups[b]!.length.compareTo(groups[a]!.length);
        if (countCompare != 0) return countCompare;
        final aIndex = _baliAreaOrder.indexOf(a);
        final bIndex = _baliAreaOrder.indexOf(b);
        if (aIndex != -1 && bIndex != -1) return aIndex.compareTo(bIndex);
        if (aIndex != -1) return -1;
        if (bIndex != -1) return 1;
        return a.compareTo(b);
      });

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
          title: const Text('Bali'),
          subtitle: Text('${spots.length} breaks • ${orderedAreas.length} surf areas'),
          children: orderedAreas
              .map(
                (area) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _AreaSection(
                    label: area,
                    spots: groups[area]!,
                    isPremium: isPremium,
                    favoriteSpotIds: favoriteSpotIds,
                    onFavoritePressed: onFavoritePressed,
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _AreaSection extends StatelessWidget {
  const _AreaSection({
    required this.label,
    required this.spots,
    required this.isPremium,
    required this.favoriteSpotIds,
    required this.onFavoritePressed,
  });

  final String label;
  final List<SpotModel> spots;
  final bool isPremium;
  final Set<String> favoriteSpotIds;
  final ValueChanged<String> onFavoritePressed;

  @override
  Widget build(BuildContext context) {
    final sorted = [...spots]..sort((a, b) => a.name.compareTo(b.name));
    final preview = sorted.take(3).map((spot) => spot.name).join(', ');

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        title: Text(label),
        subtitle: Text('${sorted.length} breaks • $preview'),
        children: sorted
            .map(
              (spot) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _SpotCard(
                  spot: spot,
                  isPremium: isPremium,
                  includeCountry: false,
                  isFavorite: favoriteSpotIds.contains(spot.id),
                  onFavoritePressed: () => onFavoritePressed(spot.id),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

String _baliAreaForSpot(SpotModel spot) {
  switch (spot.area) {
    case 'Canggu':
      return 'Canggu';
    case 'Uluwatu':
    case 'Bukit':
    case 'Nusa Dua':
      return 'Bukit / Uluwatu';
    case 'Kuta':
      return 'Kuta / Airport Reefs';
    case 'Sanur':
      return 'Sanur';
    case 'Keramas':
    case 'East Bali':
      return 'Keramas / East Bali';
    case 'West Bali':
      return 'Medewi / West Bali';
    case 'Nusa Lembongan':
    case 'Nusa Ceningan':
      return 'Nusa Lembongan';
    default:
      return 'Bukit / Uluwatu';
  }
}

class _SpotCard extends ConsumerWidget {
  const _SpotCard({
    required this.spot,
    required this.isPremium,
    required this.isFavorite,
    required this.onFavoritePressed,
    this.includeCountry = true,
  });

  final SpotModel spot;
  final bool isPremium;
  final bool isFavorite;
  final VoidCallback onFavoritePressed;
  final bool includeCountry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = includeCountry
        ? '${spot.area}, ${spot.region}, ${spot.country}'
        : '${spot.area}, ${spot.region}';
    final forecast = isPremium
        ? ref.watch(spotCardForecastProvider(spot.id))
        : const AsyncValue<ForecastModel?>.data(null);

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
        trailing: isPremium
            ? forecast.when(
                data: (row) => row == null
                    ? const SizedBox.shrink()
                    : Text(
                        row.waveDisplay,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                loading: () => const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                error: (_, _) => const SizedBox.shrink(),
              )
            : null,
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
        color: isFavorite ? _favoriteAccent : const Color(0xFF81949A),
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
