import 'package:flutter/material.dart';

import '../../core/network/api_models.dart';

const _noneValue = '__no_specific_spot__';
const _groupByRegionThreshold = 5;

class SpotPickerField extends StatelessWidget {
  const SpotPickerField({
    super.key,
    required this.spots,
    required this.favoriteSpotIds,
    required this.selectedSpotId,
    required this.onChanged,
    this.labelText = 'Spot',
    this.includeNoSpecific = false,
    this.noSpecificSubtitle = 'Post to the general feed',
  });

  final List<SpotModel> spots;
  final Set<String> favoriteSpotIds;
  final String? selectedSpotId;
  final ValueChanged<String?> onChanged;
  final String labelText;
  final bool includeNoSpecific;
  final String noSpecificSubtitle;

  @override
  Widget build(BuildContext context) {
    final selectedSpot = _spotForId(spots, selectedSpotId);
    final label = selectedSpot == null
        ? includeNoSpecific
              ? 'No specific spot'
              : 'Choose spot'
        : '${selectedSpot.name}, ${selectedSpot.area}';

    return InkWell(
      onTap: spots.isEmpty
          ? null
          : () async {
              final value = await showModalBottomSheet<String>(
                context: context,
                isScrollControlled: true,
                builder: (context) => _SpotPickerSheet(
                  spots: spots,
                  favoriteSpotIds: favoriteSpotIds,
                  selectedSpotId: selectedSpotId,
                  includeNoSpecific: includeNoSpecific,
                  noSpecificSubtitle: noSpecificSubtitle,
                ),
              );
              if (value == null) return;
              onChanged(value == _noneValue ? null : value);
            },
      borderRadius: BorderRadius.circular(16),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: labelText,
          suffixIcon: const Icon(Icons.keyboard_arrow_down),
        ),
        child: Text(label),
      ),
    );
  }
}

class _SpotPickerSheet extends StatelessWidget {
  const _SpotPickerSheet({
    required this.spots,
    required this.favoriteSpotIds,
    required this.selectedSpotId,
    required this.includeNoSpecific,
    required this.noSpecificSubtitle,
  });

  final List<SpotModel> spots;
  final Set<String> favoriteSpotIds;
  final String? selectedSpotId;
  final bool includeNoSpecific;
  final String noSpecificSubtitle;

  @override
  Widget build(BuildContext context) {
    final favoriteSpots = _sortSpots(
      spots.where((spot) => favoriteSpotIds.contains(spot.id)).toList(),
    );
    final countries = _groupSpots(spots, (spot) => spot.country);
    final countryNames = countries.keys.toList()..sort();

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD5D0C6),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('Choose spot', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (includeNoSpecific)
              _SpotPickerTile(
                title: 'No specific spot',
                subtitle: noSpecificSubtitle,
                selected: selectedSpotId == null,
                onTap: () => Navigator.of(context).pop(_noneValue),
              ),
            if (favoriteSpots.isNotEmpty) ...[
              SizedBox(height: includeNoSpecific ? 18 : 0),
              Text('Favorites', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...favoriteSpots.map(
                (spot) => _SpotPickerTile.forSpot(
                  spot,
                  selected: selectedSpotId == spot.id,
                  onTap: () => Navigator.of(context).pop(spot.id),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Text('Countries', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...countryNames.map(
              (country) => _SpotPickerCountrySection(
                country: country,
                spots: _sortSpots(countries[country]!),
                selectedSpotId: selectedSpotId,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpotPickerCountrySection extends StatelessWidget {
  const _SpotPickerCountrySection({
    required this.country,
    required this.spots,
    required this.selectedSpotId,
  });

  final String country;
  final List<SpotModel> spots;
  final String? selectedSpotId;

  @override
  Widget build(BuildContext context) {
    final shouldGroupByRegion = spots.length > _groupByRegionThreshold;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: country == 'Indonesia',
        title: Text(country),
        subtitle: Text(
          shouldGroupByRegion
              ? '${spots.length} breaks grouped by area'
              : '${spots.length} beach${spots.length == 1 ? '' : 'es'}',
        ),
        children: shouldGroupByRegion
            ? _regionSections()
            : spots
                  .map(
                    (spot) => _SpotPickerTile.forSpot(
                      spot,
                      selected: selectedSpotId == spot.id,
                      onTap: () => Navigator.of(context).pop(spot.id),
                    ),
                  )
                  .toList(),
      ),
    );
  }

  List<Widget> _regionSections() {
    final regions = _groupSpots(spots, (spot) => spot.region);
    final regionNames = regions.keys.toList()..sort();

    return regionNames
        .map(
          (region) => _SpotPickerRegionSection(
            region: region,
            spots: _sortSpots(regions[region]!),
            selectedSpotId: selectedSpotId,
          ),
        )
        .toList();
  }
}

class _SpotPickerRegionSection extends StatelessWidget {
  const _SpotPickerRegionSection({
    required this.region,
    required this.spots,
    required this.selectedSpotId,
  });

  final String region;
  final List<SpotModel> spots;
  final String? selectedSpotId;

  @override
  Widget build(BuildContext context) {
    final areas = spots.map((spot) => spot.area).toSet().toList()..sort();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF6F3ED),
          borderRadius: BorderRadius.circular(16),
        ),
        child: ExpansionTile(
          title: Text(region),
          subtitle: Text(areas.join(', ')),
          children: spots
              .map(
                (spot) => _SpotPickerTile.forSpot(
                  spot,
                  selected: selectedSpotId == spot.id,
                  onTap: () => Navigator.of(context).pop(spot.id),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _SpotPickerTile extends StatelessWidget {
  const _SpotPickerTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  factory _SpotPickerTile.forSpot(
    SpotModel spot, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return _SpotPickerTile(
      title: spot.name,
      subtitle: '${spot.area}, ${spot.region}',
      selected: selected,
      onTap: onTap,
    );
  }

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: selected ? const Icon(Icons.check_circle) : null,
      onTap: onTap,
    );
  }
}

SpotModel? _spotForId(List<SpotModel> spots, String? spotId) {
  if (spotId == null) return null;
  for (final spot in spots) {
    if (spot.id == spotId) return spot;
  }
  return null;
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

Map<String, List<SpotModel>> _groupSpots(
  List<SpotModel> spots,
  String Function(SpotModel spot) keyOf,
) {
  final groups = <String, List<SpotModel>>{};
  for (final spot in spots) {
    groups.putIfAbsent(keyOf(spot), () => []).add(spot);
  }
  return groups;
}
