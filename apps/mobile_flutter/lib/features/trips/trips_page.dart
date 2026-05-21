import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';

final tripsProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchTrips(),
);
final travelSpotsProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchSpots(),
);

class TripsPage extends ConsumerStatefulWidget {
  const TripsPage({super.key});

  @override
  ConsumerState<TripsPage> createState() => _TripsPageState();
}

class _TripsPageState extends ConsumerState<TripsPage> {
  String? _selectedCountryId;
  String? _selectedRegionId;
  String? _selectedAreaId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Travel')),
      body: ref
          .watch(travelSpotsProvider)
          .when(
            data: (spots) => _TravelLoadedBody(
              spots: spots,
              selectedCountryId: _selectedCountryId,
              selectedRegionId: _selectedRegionId,
              selectedAreaId: _selectedAreaId,
              onCountryChanged: (country) {
                setState(() {
                  _selectedCountryId = country.id;
                  _selectedRegionId = null;
                  _selectedAreaId = null;
                });
              },
              onLocationChanged: (selection) {
                setState(() {
                  _selectedRegionId = selection.regionId;
                  _selectedAreaId = selection.areaId;
                });
              },
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const _TravelLoadError(),
          ),
    );
  }
}

class _TravelLoadedBody extends StatelessWidget {
  const _TravelLoadedBody({
    required this.spots,
    required this.selectedCountryId,
    required this.selectedRegionId,
    required this.selectedAreaId,
    required this.onCountryChanged,
    required this.onLocationChanged,
  });

  final List<SpotModel> spots;
  final String? selectedCountryId;
  final String? selectedRegionId;
  final String? selectedAreaId;
  final ValueChanged<_TravelCountryView> onCountryChanged;
  final ValueChanged<_TravelLocationSelection> onLocationChanged;

  @override
  Widget build(BuildContext context) {
    final countries = _buildTravelCountries(spots);
    if (countries.isEmpty) {
      return const _TravelLoadError();
    }
    final selectedCountry = selectedCountryId == null
        ? null
        : _firstWhereOrNull(
            countries,
            (country) => country.id == selectedCountryId,
          );
    final selectedRegion = selectedCountry == null || selectedRegionId == null
        ? null
        : _firstWhereOrNull(
            selectedCountry.regions,
            (region) => region.id == selectedRegionId,
          );
    final selectedArea = selectedRegion == null || selectedAreaId == null
        ? null
        : _firstWhereOrNull(
            selectedRegion.areas,
            (area) => area.id == selectedAreaId,
          );

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const _TravelHero(),
        const SizedBox(height: 18),
        Text('Countries', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        SizedBox(
          height: 64,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: countries.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final country = countries[index];
              final selected = country.id == selectedCountry?.id;
              return _CountryChip(
                country: country,
                selected: selected,
                onTap: () => onCountryChanged(country),
              );
            },
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: Text(
                'Where to stay',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (selectedCountry != null)
              _StatusPill(label: '${selectedCountry.breakCount} breaks'),
          ],
        ),
        const SizedBox(height: 10),
        if (selectedCountry == null)
          const _PickCountryCard()
        else
          _TravelLocationButton(
            country: selectedCountry,
            region: selectedRegion,
            area: selectedArea,
            onChanged: onLocationChanged,
          ),
        const SizedBox(height: 18),
        if (selectedCountry == null)
          const SizedBox.shrink()
        else if (selectedArea == null)
          _PickTravelAreaCard(country: selectedCountry)
        else
          ...selectedArea.listings.map(
            (listing) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _TravelListingCard(listing: listing),
            ),
          ),
        const SizedBox(height: 12),
        Text('Saved living', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 10),
        const _EmptyTripPlan(),
      ],
    );
  }
}

class _TravelLoadError extends StatelessWidget {
  const _TravelLoadError();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Text('Could not load travel areas right now.'),
      ),
    );
  }
}

class _PickCountryCard extends StatelessWidget {
  const _PickCountryCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFFD7EFEC),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.public_outlined,
                color: Color(0xFF087E7A),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Choose a country to see surf regions and stay options.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickTravelAreaCard extends StatelessWidget {
  const _PickTravelAreaCard({required this.country});

  final _TravelCountryView country;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFFD7EFEC),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: Color(0xFF087E7A),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Choose a ${country.name} region and local area to see stay options.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TravelHero extends StatelessWidget {
  const _TravelHero();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF064D63), Color(0xFF0AAFB3), Color(0xFFE9B872)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.travel_explore, color: Colors.white, size: 34),
          const SizedBox(height: 26),
          Text(
            'Build the surf trip',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(color: Colors.white),
          ),
          const SizedBox(height: 8),
          const Text(
            'Find places to stay by country, surf region, and local break zone across the app.',
            style: TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _CountryChip extends StatelessWidget {
  const _CountryChip({
    required this.country,
    required this.selected,
    required this.onTap,
  });

  final _TravelCountryView country;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF143F3D) : const Color(0xFFF2EEE6),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? const Color(0xFF143F3D) : const Color(0xFFE0D8CA),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(country.emoji, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  country.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? Colors.white : const Color(0xFF263331),
                    fontSize: 13,
                    height: 1.05,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  '${country.regions.length} regions',
                  style: TextStyle(
                    color: selected ? Colors.white70 : const Color(0xFF6B6760),
                    fontSize: 11,
                    height: 1.05,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TravelLocationButton extends StatelessWidget {
  const _TravelLocationButton({
    required this.country,
    required this.region,
    required this.area,
    required this.onChanged,
  });

  final _TravelCountryView country;
  final _TravelRegionView? region;
  final _TravelAreaView? area;
  final ValueChanged<_TravelLocationSelection> onChanged;

  Future<void> _openSelector(BuildContext context) async {
    final selection = await showModalBottomSheet<_TravelLocationSelection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _TravelLocationSheet(
        country: country,
        selectedRegionId: region?.id,
        selectedAreaId: area?.id,
      ),
    );
    if (selection != null) {
      onChanged(selection);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => _openSelector(context),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFE0D8CA)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFFD7EFEC),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.place_outlined, color: Color(0xFF087E7A)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    area?.name ?? 'Choose travel area',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    area == null || region == null
                        ? '${country.name} • ${country.breakCount} breaks'
                        : '${region!.name}, ${country.name} • ${area!.breakCountLabel}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.keyboard_arrow_down_rounded),
          ],
        ),
      ),
    );
  }
}

class _TravelLocationSheet extends StatelessWidget {
  const _TravelLocationSheet({
    required this.country,
    required this.selectedRegionId,
    required this.selectedAreaId,
  });

  final _TravelCountryView country;
  final String? selectedRegionId;
  final String? selectedAreaId;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF8F7F2),
            borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: const Color(0xFFC9D0CC),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Text(
                'Choose travel area',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '${country.name} • ${country.regions.length} surf regions',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              ...country.regions.map(
                (region) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _TravelRegionTile(
                    country: country,
                    region: region,
                    selectedRegionId: selectedRegionId,
                    selectedAreaId: selectedAreaId,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TravelRegionTile extends StatelessWidget {
  const _TravelRegionTile({
    required this.country,
    required this.region,
    required this.selectedRegionId,
    required this.selectedAreaId,
  });

  final _TravelCountryView country;
  final _TravelRegionView region;
  final String? selectedRegionId;
  final String? selectedAreaId;

  @override
  Widget build(BuildContext context) {
    final expanded = selectedRegionId != null && region.id == selectedRegionId;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF2EEE6),
        borderRadius: BorderRadius.circular(22),
      ),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
        title: Text(
          region.name,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '${region.areas.length} areas • ${region.breakCountLabel}',
        ),
        children: region.areas
            .map(
              (area) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _TravelAreaTile(
                  country: country,
                  region: region,
                  area: area,
                  selected:
                      region.id == selectedRegionId &&
                      area.id == selectedAreaId,
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _TravelAreaTile extends StatelessWidget {
  const _TravelAreaTile({
    required this.country,
    required this.region,
    required this.area,
    required this.selected,
  });

  final _TravelCountryView country;
  final _TravelRegionView region;
  final _TravelAreaView area;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(area.name),
        subtitle: Text('${area.breakCountLabel} • ${area.nearSpotsLabel}'),
        trailing: selected
            ? const Icon(Icons.check_circle, color: Color(0xFF087E7A))
            : const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(
          context,
        ).pop(_TravelLocationSelection(regionId: region.id, areaId: area.id)),
      ),
    );
  }
}

class _TravelListingCard extends StatelessWidget {
  const _TravelListingCard({required this.listing});

  final _TravelListing listing;

  @override
  Widget build(BuildContext context) {
    if (listing.options.isNotEmpty) {
      return _InteractiveTravelListingCard(listing: listing);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD7EFEC),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(listing.icon),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    listing.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _StatusPill(label: listing.status),
              ],
            ),
            const SizedBox(height: 12),
            Text(listing.description),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: listing.tags
                  .map((tag) => Chip(label: Text(tag)))
                  .toList(),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton(
                  onPressed: () {},
                  child: Text(listing.primaryAction),
                ),
                const SizedBox(width: 10),
                Text(
                  'Affiliate link later',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InteractiveTravelListingCard extends StatefulWidget {
  const _InteractiveTravelListingCard({required this.listing});

  final _TravelListing listing;

  @override
  State<_InteractiveTravelListingCard> createState() =>
      _InteractiveTravelListingCardState();
}

class _InteractiveTravelListingCardState
    extends State<_InteractiveTravelListingCard> {
  late String _selectedOptionId;

  @override
  void initState() {
    super.initState();
    _selectedOptionId = widget.listing.options
        .firstWhere(
          (option) => option.places.isNotEmpty,
          orElse: () => widget.listing.options.first,
        )
        .id;
  }

  @override
  Widget build(BuildContext context) {
    final listing = widget.listing;
    final selected = listing.options.firstWhere(
      (option) => option.id == _selectedOptionId,
      orElse: () => listing.options.first,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD7EFEC),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(listing.icon),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    listing.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _StatusPill(label: listing.status),
              ],
            ),
            const SizedBox(height: 12),
            Text(selected.description),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: listing.options.map((option) {
                final isSelected = option.id == _selectedOptionId;
                return InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => setState(() => _selectedOptionId = option.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFFD7EFEC)
                          : const Color(0xFFF2EEE6),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF8FD3CD)
                            : const Color(0xFFD9D1C2),
                      ),
                    ),
                    child: Text(
                      option.label,
                      style: TextStyle(
                        color: isSelected
                            ? const Color(0xFF0A6D69)
                            : const Color(0xFF4C4A44),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            Text(
              selected.places.isEmpty
                  ? 'Official options for this stay type are landing next.'
                  : 'Book opens the official site for now. We can swap in affiliate links later.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (selected.places.isNotEmpty) ...[
              const SizedBox(height: 14),
              ...selected.places.map(
                (place) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _TravelPlaceCard(place: place),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TravelPlaceCard extends StatelessWidget {
  const _TravelPlaceCard({required this.place});

  final _TravelPlace place;

  Future<void> _open(BuildContext context, String rawUrl) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      _showLinkError(context);
      return;
    }

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      _showLinkError(context);
    }
  }

  void _showLinkError(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open that site right now.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFF7F4EE),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2DBCF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 118,
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF174642), Color(0xFFDBA15D)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(),
                Text(
                  place.stayType,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  place.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F5F2),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        place.priceHint,
                        style: const TextStyle(
                          color: Color(0xFF0A6D69),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  place.summary,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (place.distanceNote != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    place.distanceNote!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: () => _open(context, place.websiteUrl),
                      child: const Text('Website'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () =>
                          _open(context, place.bookUrl ?? place.websiteUrl),
                      child: const Text('Book'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFEDE8DA),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _EmptyTripPlan extends StatelessWidget {
  const _EmptyTripPlan();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const Icon(Icons.bookmark_add_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Your future favorite places to stay will show up here.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TravelArea {
  const _TravelArea({
    required this.id,
    required this.name,
    required this.vibe,
    required this.summary,
    required this.nearSpots,
    required this.listings,
  });

  final String id;
  final String name;
  final String vibe;
  final String summary;
  final List<String> nearSpots;
  final List<_TravelListing> listings;
}

class _TravelListing {
  const _TravelListing({
    required this.name,
    required this.category,
    required this.areaName,
    required this.description,
    required this.tags,
    required this.primaryAction,
    required this.status,
    required this.icon,
    this.options = const [],
  });

  final String name;
  final String category;
  final String areaName;
  final String description;
  final List<String> tags;
  final String primaryAction;
  final String status;
  final IconData icon;
  final List<_TravelListingOption> options;
}

class _TravelListingOption {
  const _TravelListingOption({
    required this.id,
    required this.label,
    required this.description,
    this.places = const [],
  });

  final String id;
  final String label;
  final String description;
  final List<_TravelPlace> places;
}

class _TravelPlace {
  const _TravelPlace({
    required this.name,
    required this.summary,
    required this.websiteUrl,
    this.stayType = 'Stay',
    this.priceHint = 'Pricing soon',
    this.bookUrl,
    this.distanceNote,
  });

  final String name;
  final String summary;
  final String stayType;
  final String priceHint;
  final String websiteUrl;
  final String? bookUrl;
  final String? distanceNote;
}

class _TravelCountryView {
  const _TravelCountryView({
    required this.id,
    required this.name,
    required this.emoji,
    required this.breakCount,
    required this.regions,
  });

  final String id;
  final String name;
  final String emoji;
  final int breakCount;
  final List<_TravelRegionView> regions;
}

class _TravelRegionView {
  const _TravelRegionView({
    required this.id,
    required this.name,
    required this.breakCount,
    required this.areas,
  });

  final String id;
  final String name;
  final int breakCount;
  final List<_TravelAreaView> areas;

  String get breakCountLabel =>
      breakCount == 1 ? '1 break' : '$breakCount breaks';
}

class _TravelAreaView {
  const _TravelAreaView({
    required this.id,
    required this.name,
    required this.summary,
    required this.nearSpots,
    required this.breakCount,
    required this.listings,
  });

  final String id;
  final String name;
  final String summary;
  final List<String> nearSpots;
  final int breakCount;
  final List<_TravelListing> listings;

  String get breakCountLabel {
    if (breakCount <= 0) return 'stays directory';
    return breakCount == 1 ? '1 break nearby' : '$breakCount breaks nearby';
  }

  String get nearSpotsLabel {
    if (nearSpots.isEmpty) return 'local surf base';
    return nearSpots.take(3).join(', ');
  }
}

class _TravelLocationSelection {
  const _TravelLocationSelection({
    required this.regionId,
    required this.areaId,
  });

  final String regionId;
  final String areaId;
}

List<_TravelCountryView> _buildTravelCountries(List<SpotModel> spots) {
  final countryGroups = <String, List<SpotModel>>{};
  for (final spot in spots) {
    countryGroups.putIfAbsent(spot.country, () => []).add(spot);
  }

  final countries = countryGroups.entries
      .map(
        (entry) => _TravelCountryView(
          id: _slug(entry.key),
          name: entry.key,
          emoji: _countryCode(entry.key),
          breakCount: entry.value.length,
          regions: _buildTravelRegions(entry.key, entry.value),
        ),
      )
      .where((country) => country.regions.isNotEmpty)
      .toList();

  countries.sort((a, b) {
    final rankCompare = _countryRank(a.name).compareTo(_countryRank(b.name));
    if (rankCompare != 0) return rankCompare;
    final countCompare = b.breakCount.compareTo(a.breakCount);
    if (countCompare != 0) return countCompare;
    return a.name.compareTo(b.name);
  });
  return countries;
}

List<_TravelRegionView> _buildTravelRegions(
  String country,
  List<SpotModel> countrySpots,
) {
  final regionGroups = <String, List<SpotModel>>{};
  for (final spot in countrySpots) {
    regionGroups.putIfAbsent(spot.region, () => []).add(spot);
  }

  final regions = regionGroups.entries
      .map((entry) {
        final areas = country == 'Indonesia' && entry.key == 'Bali'
            ? _buildBaliTravelAreas(entry.value)
            : _buildDynamicTravelAreas(country, entry.key, entry.value);
        return _TravelRegionView(
          id: _slug(entry.key),
          name: entry.key,
          breakCount: entry.value.length,
          areas: areas,
        );
      })
      .where((region) => region.areas.isNotEmpty)
      .toList();

  regions.sort((a, b) {
    final rankCompare = _regionRank(
      country,
      a.name,
    ).compareTo(_regionRank(country, b.name));
    if (rankCompare != 0) return rankCompare;
    final countCompare = b.breakCount.compareTo(a.breakCount);
    if (countCompare != 0) return countCompare;
    return a.name.compareTo(b.name);
  });
  return regions;
}

List<_TravelAreaView> _buildBaliTravelAreas(List<SpotModel> baliSpots) {
  return _baliAreas
      .map(
        (area) => _TravelAreaView(
          id: area.id,
          name: area.name,
          summary: area.summary,
          nearSpots: area.nearSpots,
          breakCount: _estimatedBreakCount(area, baliSpots),
          listings: area.listings.isNotEmpty
              ? area.listings
              : [_emptyLivingListing('Indonesia', 'Bali', area.name)],
        ),
      )
      .toList();
}

List<_TravelAreaView> _buildDynamicTravelAreas(
  String country,
  String region,
  List<SpotModel> regionSpots,
) {
  final areaGroups = <String, List<SpotModel>>{};
  for (final spot in regionSpots) {
    areaGroups.putIfAbsent(spot.area, () => []).add(spot);
  }

  final areas = areaGroups.entries.map((entry) {
    final nearSpots = entry.value.map((spot) => spot.name).take(4).toList();
    return _TravelAreaView(
      id: _slug(entry.key),
      name: entry.key,
      summary:
          'Places to stay around ${entry.key} for surfers using $region as a home base.',
      nearSpots: nearSpots,
      breakCount: entry.value.length,
      listings: [_emptyLivingListing(country, region, entry.key)],
    );
  }).toList();

  areas.sort((a, b) {
    final countCompare = b.breakCount.compareTo(a.breakCount);
    if (countCompare != 0) return countCompare;
    return a.name.compareTo(b.name);
  });
  return areas;
}

_TravelListing _emptyLivingListing(
  String country,
  String region,
  String areaName,
) {
  final description =
      'Places to stay around $areaName for surfers planning $region sessions in $country.';
  return _TravelListing(
    name: '$areaName living',
    category: 'Living',
    areaName: areaName,
    description: description,
    tags: const ['Hostels', 'Villas', 'Hotels', 'Guesthouses'],
    primaryAction: 'Find places to stay',
    status: 'Soon',
    icon: Icons.bed_outlined,
    options: [
      _TravelListingOption(
        id: 'hostels',
        label: 'Hostels',
        description:
            'Hostels near $areaName for social surf stays, easier budgeting, and meeting people nearby.',
      ),
      _TravelListingOption(
        id: 'villas',
        label: 'Villas',
        description:
            'Villas near $areaName for groups, longer stays, and a more private surf-trip base.',
      ),
      _TravelListingOption(
        id: 'hotels',
        label: 'Hotels',
        description:
            'Hotels near $areaName for private rooms, amenities, and easier travel logistics.',
      ),
      _TravelListingOption(
        id: 'guesthouses',
        label: 'Guesthouses',
        description:
            'Guesthouses near $areaName for simpler private stays with lighter prices.',
      ),
    ],
  );
}

int _estimatedBreakCount(_TravelArea area, List<SpotModel> spots) {
  final name = area.name.toLowerCase();
  final nearSpotNames = area.nearSpots
      .map((spot) => spot.toLowerCase())
      .toSet();
  final matches = spots.where((spot) {
    final spotArea = spot.area.toLowerCase();
    final spotName = spot.name.toLowerCase();
    if (nearSpotNames.contains(spotName)) return true;
    if (name.contains(spotArea) || spotArea.contains(name)) return true;
    if (area.id == 'kuta_seminyak') {
      return spotArea == 'kuta' ||
          spotName.contains('kuta') ||
          spotName.contains('legian') ||
          spotName.contains('seminyak');
    }
    if (area.id == 'sanur_nusa_dua') {
      return spotArea == 'sanur' || spotArea == 'nusa dua';
    }
    if (area.id == 'keramas') {
      return spotArea == 'keramas' || spotArea == 'east bali';
    }
    if (area.id == 'medewi') {
      return spotArea == 'west bali' || spotName.contains('medewi');
    }
    if (area.id == 'nusa_lembongan') {
      return spotArea.contains('lembongan') || spotArea.contains('ceningan');
    }
    return false;
  }).length;
  return matches == 0 ? area.nearSpots.length : matches;
}

String _slug(String value) {
  final slug = value
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '_')
      .replaceAll(RegExp('^_+|_+\$'), '');
  return slug.isEmpty ? 'area' : slug;
}

String _countryCode(String country) {
  const codes = {
    'Australia': 'AU',
    'Indonesia': 'ID',
    'Malaysia': 'MY',
    'Myanmar': 'MM',
    'Philippines': 'PH',
    'Sri Lanka': 'LK',
    'Thailand': 'TH',
    'Timor-Leste': 'TL',
    'Vietnam': 'VN',
  };
  return codes[country] ?? country.characters.take(2).toString().toUpperCase();
}

int _countryRank(String country) {
  const order = [
    'Australia',
    'Indonesia',
    'Sri Lanka',
    'Philippines',
    'Thailand',
    'Vietnam',
    'Malaysia',
    'Myanmar',
    'Timor-Leste',
  ];
  final index = order.indexOf(country);
  return index == -1 ? 999 : index;
}

int _regionRank(String country, String region) {
  const orders = {
    'Indonesia': [
      'Bali',
      'Lombok',
      'Java',
      'Nias',
      'Mentawai',
      'Sumbawa',
      'Sumatra',
      'Rote',
    ],
    'Australia': [
      'New South Wales',
      'Queensland',
      'Victoria',
      'Western Australia',
      'South Australia',
      'Tasmania',
    ],
  };
  final order = orders[country] ?? const <String>[];
  final index = order.indexOf(region);
  return index == -1 ? 999 : index;
}

T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T item) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}

const _baliAreas = [
  _TravelArea(
    id: 'canggu',
    name: 'Canggu',
    vibe: 'Social',
    summary:
        'Busy surf town with hostels, cafes, board rentals, beginner-friendly beach breaks, and lots of people to meet.',
    nearSpots: ['Echo Beach', 'Batu Bolong', 'Berawa'],
    listings: [
      _TravelListing(
        name: 'Canggu living',
        category: 'Living',
        areaName: 'Canggu',
        description:
            'Places to stay in Canggu for surfers who want nightlife, cafes, easy beach access, and lots of people around.',
        tags: ['Hostels', 'Villas', 'Hotels'],
        primaryAction: 'Find places to stay',
        status: 'Listed',
        icon: Icons.bed_outlined,
        options: [
          _TravelListingOption(
            id: 'hostels',
            label: 'Hostels',
            description:
                'Hostels in Canggu for social stays, easier budgeting, and meeting other surfers near cafes and beach zones.',
            places: [
              _TravelPlace(
                name: 'Kos One Hostel',
                summary:
                    'Boutique social hostel near Batu Bolong with a pool, events, and a strong surf-traveler vibe.',
                stayType: 'Hostel',
                priceHint: 'Approx. \$18-40/night',
                websiteUrl: 'https://www.kosonehostel.com/',
                bookUrl: 'https://www.kosonehostel.com/',
                distanceNote:
                    'A few minutes from Batu Bolong and central Canggu.',
              ),
              _TravelPlace(
                name: 'Margarita Surf Hostel Canggu',
                summary:
                    'Social surf hostel with dorms, a pool, common areas, and easy access to Canggu cafes and beach zones.',
                stayType: 'Hostel',
                priceHint: 'Approx. \$12-30/night',
                websiteUrl: 'https://surfhostelcanggu.com/',
                distanceNote:
                    'About 5-10 minutes by bike to Batu Bolong and Echo.',
              ),
              _TravelPlace(
                name: 'Zentiga Bali',
                summary:
                    'Canggu hostel with cowork-friendly vibes, surf packages, and a walkable location near cafes and beaches.',
                stayType: 'Hostel',
                priceHint: 'Approx. \$15-35/night',
                websiteUrl: 'https://zentigahostel.com/',
                distanceNote:
                    'Walkable to central Canggu spots and nearby surf.',
              ),
              _TravelPlace(
                name: 'Seabreeze Hostel Bali',
                summary:
                    'Community hostel with a short walk to the beach, social spaces, and surf-focused energy.',
                stayType: 'Hostel',
                priceHint: 'Approx. \$15-35/night',
                websiteUrl: 'https://www.seabreezehostel.com/',
                distanceNote: 'Roughly a 6-minute walk to the beach.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'villas',
            label: 'Villas',
            description:
                'Private villas in Canggu for more comfort, groups, longer stays, or a quieter home base between sessions.',
            places: [
              _TravelPlace(
                name: 'Kharista Canggu Villas & Retreat',
                summary:
                    'Eco-conscious villa retreat in bohemian Canggu with private pool villa options and a polished tropical feel.',
                stayType: 'Villa',
                priceHint: 'Approx. \$120-260/night',
                websiteUrl: 'https://kharistacanggu.com/',
                distanceNote:
                    'Close to Canggu cafes, surf spots, and sunset areas.',
              ),
              _TravelPlace(
                name: 'Villa Canggu',
                summary:
                    'Multi-bedroom villa setup near Echo Beach that suits groups who want more space and privacy.',
                stayType: 'Villa',
                priceHint: 'Approx. \$140-320/night',
                websiteUrl: 'https://www.villacanggu.com/',
                distanceNote: 'About 100 metres from the beach near Echo.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'hotels',
            label: 'Hotels',
            description:
                'Hotel-style stays in Canggu for cleaner amenities, private rooms, and easy transport access.',
            places: [
              _TravelPlace(
                name: 'The Bali Dream Villa & Resort Echo Beach Canggu',
                summary:
                    'Resort-style stay with rooms and pool villas, plus spa and restaurant facilities near Echo Beach.',
                stayType: 'Hotel',
                priceHint: 'Approx. \$85-180/night',
                websiteUrl: 'https://www.thebalidreamvillaresort.com/',
                distanceNote:
                    'Pererenan side, with shuttle access toward Echo Beach.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'guesthouses',
            label: 'Guesthouses',
            description:
                'Guesthouses in Canggu for simpler private stays with a lighter price point and easy beach-town access.',
            places: [
              _TravelPlace(
                name: 'The Calmtree Bungalows',
                summary:
                    'Family-run tropical bungalow stay with pool, gardens, and a relaxed Canggu village feel.',
                stayType: 'Guesthouse',
                priceHint: 'Approx. \$35-75/night',
                websiteUrl: 'https://thecalmtreebungalows.com/',
                distanceNote:
                    'About a 10-minute walk to Batu Bolong and Echo Beach.',
              ),
            ],
          ),
        ],
      ),
    ],
  ),
  _TravelArea(
    id: 'uluwatu',
    name: 'Uluwatu',
    vibe: 'Reefs',
    summary:
        'Bukit reef zone with legendary breaks, cliff stays, scooters, and rentals for intermediate to advanced surfers.',
    nearSpots: ['Uluwatu Peak', 'Padang Padang', 'Balangan', 'Bingin'],
    listings: [
      _TravelListing(
        name: 'Uluwatu living',
        category: 'Living',
        areaName: 'Uluwatu',
        description:
            'Places to stay around the Bukit for reef missions, cliff sunsets, and easy access to Uluwatu-side breaks.',
        tags: ['Hostels', 'Villas', 'Guesthouses'],
        primaryAction: 'Find places to stay',
        status: 'Listed',
        icon: Icons.bed_outlined,
        options: [
          _TravelListingOption(
            id: 'hostels',
            label: 'Hostels',
            description:
                'Hostels in Uluwatu for surfers who want social stays and easier access to the Bukit without paying villa prices.',
            places: [
              _TravelPlace(
                name: 'Kala Surf',
                summary:
                    'Social surf camp with coaching, breakfast, gym space, and a beach-close setup in the Uluwatu zone.',
                stayType: 'Hostel',
                priceHint: 'Approx. \$20-45/night',
                websiteUrl: 'https://www.kala.surf/',
                distanceNote:
                    'Built for surfers staying near Padang Padang, Bingin, and the Bukit reef zone.',
              ),
              _TravelPlace(
                name: 'Surf Camp Uluwatu',
                summary:
                    'Accommodation-led surf camp for all levels with coaching and easy access to the main Uluwatu breaks.',
                stayType: 'Hostel',
                priceHint: 'Approx. \$18-40/night',
                websiteUrl: 'https://www.surfcampuluwatu.com/',
                distanceNote:
                    'Good base for Uluwatu, Padang Padang, Bingin, and nearby reef missions.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'villas',
            label: 'Villas',
            description:
                'Villas in Uluwatu for more comfort, cliff views, and a stronger home base between reef sessions.',
            places: [
              _TravelPlace(
                name: 'Villa Carina Bali',
                summary:
                    'Private pool villa stay in the Uluwatu area for couples or longer surf trips that want more privacy.',
                stayType: 'Villa',
                priceHint: 'Approx. \$110-240/night',
                websiteUrl: 'https://www.villacarinabali.com/book-now',
                distanceNote:
                    'Ungasan side, with quick scooter access toward Melasti and the wider Bukit.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'hotels',
            label: 'Hotels',
            description:
                'Hotels in Uluwatu for private rooms, stronger amenities, and easier comfort between surf sessions.',
            places: [
              _TravelPlace(
                name: 'Anantara Uluwatu Bali Resort',
                summary:
                    'Clifftop resort with ocean views, direct surf energy below, and a more polished stay setup.',
                stayType: 'Hotel',
                priceHint: 'Approx. \$260+/night',
                websiteUrl: 'https://www.anantara.com/en/uluwatu-bali',
                distanceNote:
                    'Near Impossible Beach and well placed for a higher-end Bukit stay.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'guesthouses',
            label: 'Guesthouses',
            description:
                'Guesthouses in Uluwatu for simpler private stays close to the reef zone and local food spots.',
            places: [
              _TravelPlace(
                name: 'Tregge Surf Camp Uluwatu',
                summary:
                    'Quiet private-room stay with easy beach access and a calmer pace than the bigger camp setups.',
                stayType: 'Guesthouse',
                priceHint: 'Approx. \$35-80/night',
                websiteUrl: 'https://www.treggesurfcampuluwatu.com/',
                distanceNote:
                    'Good for surfers who want simple Uluwatu days without the full social-hostel vibe.',
              ),
            ],
          ),
        ],
      ),
    ],
  ),
  _TravelArea(
    id: 'kuta_seminyak',
    name: 'Kuta / Seminyak',
    vibe: 'Beginner',
    summary:
        'Easy access beach-break zone with lots of beginner lessons, cheap rentals, shopping, nightlife, and airport proximity.',
    nearSpots: ['Kuta Beach', 'Legian', 'Seminyak'],
    listings: [
      _TravelListing(
        name: 'Kuta / Seminyak living',
        category: 'Living',
        areaName: 'Kuta / Seminyak',
        description:
            'Places to stay close to the beach, airport, shopping, and nightlife for easy-access Bali trips.',
        tags: ['Hostels', 'Hotels', 'Villas'],
        primaryAction: 'Find places to stay',
        status: 'Listed',
        icon: Icons.bed_outlined,
        options: [
          _TravelListingOption(
            id: 'hostels',
            label: 'Hostels',
            description:
                'Hostels in Kuta and Seminyak for budget-friendly stays close to nightlife and easy beach access.',
            places: [
              _TravelPlace(
                name: 'Lokal Bali Hostel',
                summary:
                    'Friendly Kuta-area hostel with pool, common spaces, and an easy airport-side base before or after a surf trip.',
                stayType: 'Hostel',
                priceHint: 'Approx. \$12-28/night',
                websiteUrl: 'https://www.lokalbalihostel.com/',
                distanceNote:
                    'Convenient for airport arrivals, Kuta beach, and getting around south Bali fast.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'villas',
            label: 'Villas',
            description:
                'Villa options in Kuta and Seminyak for groups, comfort, and a more private stay setup.',
            places: [
              _TravelPlace(
                name: 'The Bali Dream Villa Seminyak',
                summary:
                    'Private pool villa stay for groups or couples who want a quieter base near Seminyak nightlife and food.',
                stayType: 'Villa',
                priceHint: 'Approx. \$120-260/night',
                websiteUrl: 'https://www.thebalidreamvilla.com/',
                distanceNote:
                    'Short ride to Seminyak Beach, restaurants, and shopping zones.',
              ),
              _TravelPlace(
                name: 'The Kumpi Villas',
                summary:
                    'Boutique private villas in central Seminyak with a more polished home-base feel.',
                stayType: 'Villa',
                priceHint: 'Approx. \$180-350/night',
                websiteUrl: 'https://www.thekumpivillas.com/',
                distanceNote:
                    'Good for Seminyak stays that prioritize privacy but still want to stay central.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'hotels',
            label: 'Hotels',
            description:
                'Hotels in Kuta and Seminyak for private rooms, amenities, and easier airport-area logistics.',
            places: [
              _TravelPlace(
                name: 'The Colony Hotel Bali',
                summary:
                    'Boutique Seminyak hotel close to the beach clubs, restaurants, and the heart of the area.',
                stayType: 'Hotel',
                priceHint: 'Approx. \$130-260/night',
                websiteUrl: 'https://www.thecolonyhotelbali.com/',
                distanceNote:
                    'Walkable around Petitenget and close to the main Seminyak scene.',
              ),
              _TravelPlace(
                name: 'iSuite Seminyak',
                summary:
                    'Contemporary boutique hotel stay in Seminyak for people who want an urban-feeling Bali base.',
                stayType: 'Hotel',
                priceHint: 'Approx. \$70-140/night',
                websiteUrl: 'https://www.isuitebali.com/',
                distanceNote:
                    'Handy for Seminyak restaurants, bars, and short beach runs.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'guesthouses',
            label: 'Guesthouses',
            description:
                'Guesthouses in Kuta and Seminyak for simpler private stays with easy access to cafes, shops, and beaches.',
          ),
        ],
      ),
    ],
  ),
  _TravelArea(
    id: 'keramas',
    name: 'Keramas / East Bali',
    vibe: 'Power',
    summary:
        'Right-hand reef zone with heavier waves, quieter stays, and day-trip style logistics from south Bali.',
    nearSpots: ['Keramas', 'Sanur reefs', 'Nusa Dua'],
    listings: [
      _TravelListing(
        name: 'Keramas living',
        category: 'Living',
        areaName: 'Keramas / East Bali',
        description:
            'Places to stay and quieter surf-base options for people chasing right-hand reef waves away from the Canggu crowd.',
        tags: ['Guesthouses', 'Villas', 'Surf camps'],
        primaryAction: 'Find places to stay',
        status: 'Listed',
        icon: Icons.bed_outlined,
        options: [
          _TravelListingOption(
            id: 'hostels',
            label: 'Hostels',
            description:
                'Hostels near Keramas for budget surfers who still want quick access to east-side reef sessions.',
          ),
          _TravelListingOption(
            id: 'villas',
            label: 'Villas',
            description:
                'Villa options around Keramas for more private surf stays and calmer nights away from busier zones.',
            places: [
              _TravelPlace(
                name: 'Utamas Keramas Villa',
                summary:
                    'Private-pool villa stay set near Keramas with rice-field views and quick beach access.',
                stayType: 'Villa',
                priceHint: 'Approx. \$90-190/night',
                websiteUrl: 'https://www.utamaskeramas.com/en/',
                distanceNote:
                    'About a 5-minute walk to Keramas Beach from the villa area.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'hotels',
            label: 'Hotels',
            description:
                'Hotels near Keramas for more amenities, privacy, and easier east-side trip comfort.',
            places: [
              _TravelPlace(
                name: 'Hotel Komune Bali',
                summary:
                    'Beachfront Keramas resort with rooms, suites, villas, and a direct surf-break location.',
                stayType: 'Hotel',
                priceHint: 'Approx. \$120-260/night',
                websiteUrl: 'https://komuneresorts.com/',
                distanceNote:
                    'Right on the Keramas surf break for the easiest dawn-patrol setup.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'guesthouses',
            label: 'Guesthouses',
            description:
                'Guesthouses around Keramas for quieter private stays and easier dawn-mission routines.',
          ),
        ],
      ),
    ],
  ),
  _TravelArea(
    id: 'medewi',
    name: 'Medewi',
    vibe: 'Mellow',
    summary:
        'Long left point area for slower surf trips, longboards, fewer crowds, and cheap guesthouses.',
    nearSpots: ['Medewi', 'Balian'],
    listings: [
      _TravelListing(
        name: 'Medewi living',
        category: 'Living',
        areaName: 'Medewi',
        description:
            'Budget places to stay near mellow point waves and quieter village-style travel.',
        tags: ['Guesthouses', 'Hotels', 'Villas'],
        primaryAction: 'Find places to stay',
        status: 'Listed',
        icon: Icons.bed_outlined,
        options: [
          _TravelListingOption(
            id: 'hostels',
            label: 'Hostels',
            description:
                'Hostels in Medewi for budget-friendly stays and slower surf trips near mellow point waves.',
            places: [
              _TravelPlace(
                name: 'Brown Sugar Surf Camp Medewi',
                summary:
                    'Beachfront surf camp in Medewi with bungalow-style stays and a laid-back long-left vibe.',
                stayType: 'Hostel',
                priceHint: 'Approx. \$18-45/night',
                websiteUrl: 'https://brownsugarsurf.com/surf-camp/',
                distanceNote:
                    'Directly by the beach and built around Medewi’s slower trip rhythm.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'villas',
            label: 'Villas',
            description:
                'Villa options in Medewi for quieter private stays and slower surf-trip pacing.',
          ),
          _TravelListingOption(
            id: 'hotels',
            label: 'Hotels',
            description:
                'Hotel-style options in Medewi for more amenities while keeping the relaxed point-wave vibe.',
          ),
          _TravelListingOption(
            id: 'guesthouses',
            label: 'Guesthouses',
            description:
                'Guesthouses in Medewi for simple long-stay surf trips with a relaxed village feel.',
          ),
        ],
      ),
    ],
  ),
  _TravelArea(
    id: 'sanur_nusa_dua',
    name: 'Sanur / Nusa Dua',
    vibe: 'Seasonal',
    summary:
        'East-side reef and resort zone, more seasonal and wind dependent, useful for alternate swell/wind days.',
    nearSpots: ['Sanur reefs', 'Nusa Dua'],
    listings: [
      _TravelListing(
        name: 'Sanur / Nusa Dua living',
        category: 'Living',
        areaName: 'Sanur / Nusa Dua',
        description:
            'Places to stay around Sanur and Nusa Dua for east-side surf days, cleaner amenities, and easier resort-area logistics.',
        tags: ['Hotels', 'Villas', 'Guesthouses'],
        primaryAction: 'Find places to stay',
        status: 'Listed',
        icon: Icons.bed_outlined,
        options: [
          _TravelListingOption(
            id: 'hostels',
            label: 'Hostels',
            description:
                'Hostels in Sanur and Nusa Dua for lighter budgets and easy access to east-side travel zones.',
          ),
          _TravelListingOption(
            id: 'villas',
            label: 'Villas',
            description:
                'Villa options in Sanur and Nusa Dua for more privacy and a calmer travel base.',
          ),
          _TravelListingOption(
            id: 'hotels',
            label: 'Hotels',
            description:
                'Hotels in Sanur and Nusa Dua for cleaner amenities, private rooms, and easier resort-style stays.',
            places: [
              _TravelPlace(
                name: 'Sanur House',
                summary:
                    'Boutique hotel-style stay in central Sanur for a quieter Bali base with nicer amenities.',
                stayType: 'Hotel',
                priceHint: 'Approx. \$55-120/night',
                websiteUrl: 'https://www.sanurhouse.com/',
                distanceNote:
                    'Good for Sanur beach days, ferry access, and east-side missions.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'guesthouses',
            label: 'Guesthouses',
            description:
                'Guesthouses around Sanur and Nusa Dua for simpler stays and lighter budgets.',
            places: [
              _TravelPlace(
                name: 'Sanur Guest House',
                summary:
                    'Small friendly guesthouse near Sanur Beach with a simple setup that works well before island transfers.',
                stayType: 'Guesthouse',
                priceHint: 'Approx. \$25-55/night',
                websiteUrl: 'https://www.sanurguesthouse.com/',
                distanceNote:
                    'Near Sanur beach and handy for boats to Lembongan, Penida, and the Gilis.',
              ),
              _TravelPlace(
                name: 'Kembali Lagi Guest House & Villas',
                summary:
                    'Award-winning guesthouse setup in Sanur with a relaxed neighborhood feel and villa options too.',
                stayType: 'Guesthouse',
                priceHint: 'Approx. \$40-90/night',
                websiteUrl: 'https://www.kembalilagi.com/',
                distanceNote:
                    'Easy stroll to shops, cafes, and the Sanur beachside community.',
              ),
            ],
          ),
        ],
      ),
    ],
  ),
  _TravelArea(
    id: 'nusa_lembongan',
    name: 'Nusa Lembongan',
    vibe: 'Island',
    summary:
        'Island reef setup with boat logistics, surf stays, rental leads, and breaks like Shipwrecks and Lacerations.',
    nearSpots: ['Shipwrecks', 'Lacerations', 'Playgrounds'],
    listings: [
      _TravelListing(
        name: 'Lembongan living',
        category: 'Living',
        areaName: 'Nusa Lembongan',
        description:
            'Island places to stay for surfers who want reef waves, boats, and a slower trip outside mainland Bali.',
        tags: ['Hostels', 'Villas', 'Hotels'],
        primaryAction: 'Find places to stay',
        status: 'Listed',
        icon: Icons.bed_outlined,
        options: [
          _TravelListingOption(
            id: 'hostels',
            label: 'Hostels',
            description:
                'Hostels in Lembongan for budget island stays, social travelers, and surfers chasing reef waves.',
            places: [
              _TravelPlace(
                name: '3 Monkeys Lembongan Surf Camp',
                summary:
                    'Surf camp stay on Nusa Lembongan built around reef sessions, shared rooms, and island surf routines.',
                stayType: 'Hostel',
                priceHint: 'Approx. \$20-45/night',
                websiteUrl: 'https://3monkeyslembongan.com/surf-camp/',
                distanceNote:
                    'Set up for surfers heading to Shipwrecks, Lacerations, and Playgrounds.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'villas',
            label: 'Villas',
            description:
                'Villa options in Lembongan for more comfort, island views, and longer stays outside mainland Bali.',
          ),
          _TravelListingOption(
            id: 'hotels',
            label: 'Hotels',
            description:
                'Hotel-style options in Lembongan for cleaner amenities and easier island logistics.',
            places: [
              _TravelPlace(
                name: 'Ohana’s Beachfront Resort',
                summary:
                    'Beachfront resort in Jungut Batu with walkable food spots and direct island-stay convenience.',
                stayType: 'Hotel',
                priceHint: 'Approx. \$95-190/night',
                websiteUrl: 'https://www.ohanas.co/stay',
                distanceNote:
                    'In the main town area with quick access toward Shipwrecks and nearby reef breaks.',
              ),
              _TravelPlace(
                name: 'The Ulu Beach Club & Bungalows',
                summary:
                    'Beach club and bungalow-style stay for a more polished island trip with ocean views.',
                stayType: 'Hotel',
                priceHint: 'Approx. \$80-170/night',
                websiteUrl: 'https://www.theululembongan.com/',
                distanceNote:
                    'Good fit if you want a hotel-style island base instead of a full surf-camp setup.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'guesthouses',
            label: 'Guesthouses',
            description:
                'Guesthouses in Lembongan for simpler private island stays with lighter budgets and easier local access.',
          ),
        ],
      ),
    ],
  ),
  _TravelArea(
    id: 'amed',
    name: 'Amed / North East',
    vibe: 'Explore',
    summary:
        'Less obvious surf-travel zone, better for quiet stays, diving, scooters, and exploratory missions.',
    nearSpots: ['Amed coast', 'East Bali reefs'],
    listings: [
      _TravelListing(
        name: 'Amed living',
        category: 'Living',
        areaName: 'Amed / North East',
        description:
            'Quiet places to stay for people adding diving, scooters, and exploration to a Bali trip.',
        tags: ['Guesthouses', 'Villas', 'Hotels'],
        primaryAction: 'Find places to stay',
        status: 'Listed',
        icon: Icons.bed_outlined,
        options: [
          _TravelListingOption(
            id: 'hostels',
            label: 'Hostels',
            description:
                'Hostels in Amed for budget-minded stays and slower travel around the east coast.',
          ),
          _TravelListingOption(
            id: 'villas',
            label: 'Villas',
            description:
                'Villa options in Amed for private stays and a more relaxed exploration base.',
            places: [
              _TravelPlace(
                name: 'Villa Di Amed',
                summary:
                    'Relaxed villa-style stay in Amed that works well for quieter Bali trips mixing surf, diving, and downtime.',
                stayType: 'Villa',
                priceHint: 'Approx. \$80-160/night',
                websiteUrl: 'https://www.villadiamed.com/',
                distanceNote:
                    'Good base for east-coast exploring, diving, and mellow days away from the south.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'hotels',
            label: 'Hotels',
            description:
                'Hotel-style options in Amed for comfort, amenities, and a cleaner home base while exploring.',
            places: [
              _TravelPlace(
                name: 'Baliku Dive Resort',
                summary:
                    'Hillside resort stay in Amed with villa-style rooms and wide views over the east coast.',
                stayType: 'Hotel',
                priceHint: 'Approx. \$70-140/night',
                websiteUrl: 'https://www.amedbaliresort.com/',
                distanceNote:
                    'Best for a quieter Amed base mixing coastline exploring with a more comfortable stay.',
              ),
            ],
          ),
          _TravelListingOption(
            id: 'guesthouses',
            label: 'Guesthouses',
            description:
                'Guesthouses in Amed for quiet budgets, diving days, and a simpler east-coast stay style.',
            places: [
              _TravelPlace(
                name: 'Bunga Laut Bungalow',
                summary:
                    'Simple bungalow stay in Amed for slower days, lighter budgets, and an easy village feel.',
                stayType: 'Guesthouse',
                priceHint: 'Approx. \$25-60/night',
                websiteUrl: 'https://amedhotel.com/',
                distanceNote:
                    'Fits travelers mixing diving, exploring, and a quieter Bali finish.',
              ),
            ],
          ),
        ],
      ),
    ],
  ),
];
