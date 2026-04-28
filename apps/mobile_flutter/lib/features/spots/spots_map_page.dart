import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import 'spots_page.dart';

const _mapMarkerBlue = Color(0xFF3E9FA3);
const _mapMarkerBlueDark = Color(0xFF0B6E6E);
const _favoriteAccent = Color(0xFF2AA7A1);
const _allCountriesLabel = 'All Southeast Asia';
const _allRegionsLabel = 'All regions';
const _allAreasLabel = 'All areas';

class SpotsMapPage extends ConsumerStatefulWidget {
  const SpotsMapPage({
    super.key,
    this.initialSpotId,
  });

  final String? initialSpotId;

  @override
  ConsumerState<SpotsMapPage> createState() => _SpotsMapPageState();
}

class _SpotsMapPageState extends ConsumerState<SpotsMapPage> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();

  String _selectedCountry = _allCountriesLabel;
  String _selectedRegion = _allRegionsLabel;
  String _selectedArea = _allAreasLabel;
  String? _selectedSpotId;
  double _zoom = 3.2;
  bool _savedOnly = false;
  bool _didApplyInitialSpot = false;

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

    return Scaffold(
      appBar: AppBar(title: const Text('Spot map')),
      body: spots.when(
        data: (items) {
          final sourceItems = _savedOnly
              ? items
                    .where((spot) => favoriteSpotIds.contains(spot.id))
                    .toList()
              : items;

          if (!_didApplyInitialSpot && widget.initialSpotId != null) {
            SpotModel? initialSpot;
            for (final spot in sourceItems) {
              if (spot.id == widget.initialSpotId) {
                initialSpot = spot;
                break;
              }
            }
            if (initialSpot != null) {
              final targetSpot = initialSpot;
              _didApplyInitialSpot = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _focusSpot(targetSpot);
              });
            }
          }

          if (sourceItems.isEmpty) {
            return Center(
              child: Text(
                _savedOnly
                    ? 'No saved spots to show on the map yet.'
                    : 'No spots available yet.',
              ),
            );
          }

          final visibleSpots = _visibleSpotsFor(sourceItems);
          final selectedSpot = visibleSpots.where((spot) => spot.id == _selectedSpotId).isEmpty
              ? null
              : visibleSpots.firstWhere((spot) => spot.id == _selectedSpotId);

          return ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: Column(
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.favorite_outline),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text('Show saved spots only'),
                            ),
                            Switch(
                              value: _savedOnly,
                              onChanged: (value) {
                                setState(() {
                                  _savedOnly = value;
                                  _selectedCountry = _allCountriesLabel;
                                  _selectedRegion = _allRegionsLabel;
                                  _selectedArea = _allAreasLabel;
                                  _selectedSpotId = null;
                                });
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  _showSpots(_visibleSpotsFor(value
                                      ? items
                                            .where(
                                              (spot) => favoriteSpotIds.contains(
                                                spot.id,
                                              ),
                                            )
                                            .toList()
                                      : items));
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {
                        _selectedSpotId = null;
                      }),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search spots on the map',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchQuery.isEmpty
                            ? null
                            : IconButton(
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {
                                    _selectedSpotId = null;
                                  });
                                },
                                icon: const Icon(Icons.close),
                              ),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _LocationPickerField(
                      sourceItems: sourceItems,
                      favoriteSpotIds: favoriteSpotIds,
                      selectedCountry: _selectedCountry,
                      selectedRegion: _selectedRegion,
                      selectedArea: _selectedArea,
                      selectedSpotId: _selectedSpotId,
                      onChanged: (selection) {
                        setState(() {
                          _selectedCountry = selection.country;
                          _selectedRegion = selection.region;
                          _selectedArea = selection.area;
                          _selectedSpotId = selection.spotId;
                        });
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          final nextVisible = _visibleSpotsFor(sourceItems);
                          if (selection.spotId != null &&
                              nextVisible.any(
                                (spot) => spot.id == selection.spotId,
                              )) {
                            _focusSpot(
                              nextVisible.firstWhere(
                                (spot) => spot.id == selection.spotId,
                              ),
                            );
                          } else {
                            _showSpots(nextVisible);
                          }
                        });
                      },
                    ),
                  ],
                ),
              ),
              if (visibleSpots.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Card(
                    child: Padding(
                      padding: EdgeInsets.all(18),
                      child: Text(
                        'No spots match that search in this location. Try another break, another area, or clear the search.',
                      ),
                    ),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Text(
                    'Use normal map gestures on iPhone: pinch to zoom, drag to pan. On Mac, use trackpad pinch or scroll.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    height: 300,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: _MapCanvas(
                        mapController: _mapController,
                        spots: visibleSpots,
                        initialCenter: _centerOf(visibleSpots),
                        initialZoom:
                            _selectedCountry == _allCountriesLabel &&
                                _selectedRegion == _allRegionsLabel &&
                                _selectedArea == _allAreasLabel
                            ? 3.2
                            : 8.0,
                        selectedSpotId: _selectedSpotId,
                        onSpotTap: _focusSpot,
                        onPositionChanged: (camera, _) {
                          if (_zoom != camera.zoom) {
                            setState(() => _zoom = camera.zoom);
                          }
                        },
                      ),
                    ),
                  ),
                ),
                if (selectedSpot != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 56,
                              decoration: BoxDecoration(
                                color: _difficultyColor(selectedSpot.difficulty),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    selectedSpot.name,
                                    style: Theme.of(context).textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${selectedSpot.area}, ${selectedSpot.region}, ${selectedSpot.country}',
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '${selectedSpot.waveHeightM}m waves • ${selectedSpot.difficulty}',
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () => ref
                                  .read(favoriteSpotIdsProvider.notifier)
                                  .toggle(selectedSpot.id),
                              icon: Icon(
                                favoriteSpotIds.contains(selectedSpot.id)
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: favoriteSpotIds.contains(selectedSpot.id)
                                    ? _favoriteAccent
                                    : const Color(0xFF81949A),
                              ),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  context.push('/spot/${selectedSpot.id}'),
                              child: const Text('Open'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(18),
                        child: Text(
                          'Tap a dot on the map or choose a break from Location to open one.',
                        ),
                      ),
                    ),
                  ),
                ..._buildResultList(
                  context: context,
                  visibleSpots: visibleSpots,
                  favoriteSpotIds: favoriteSpotIds,
                  selectedSpot: selectedSpot,
                ),
              ],
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Could not load map: $error')),
      ),
    );
  }

  void _focusSpot(SpotModel spot, {double zoom = 9.2}) {
    _mapController.move(LatLng(spot.latitude, spot.longitude), zoom);
    setState(() {
      _selectedSpotId = spot.id;
      _zoom = zoom;
      _selectedCountry = spot.country;
      _selectedRegion = spot.region;
      _selectedArea = _locationAreaForSpot(spot);
    });
  }

  void _showSpots(List<SpotModel> spots) {
    if (spots.isEmpty) return;
    final bounds = LatLngBounds.fromPoints(
      spots.map((spot) => LatLng(spot.latitude, spot.longitude)).toList(),
    );
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.fromLTRB(36, 36, 36, 36),
      ),
    );
    setState(() {
      _selectedSpotId = null;
      _zoom = _mapController.camera.zoom;
    });
  }

  List<SpotModel> _visibleSpotsFor(List<SpotModel> items) {
    final countrySpots = filteredForCountry(items, _selectedCountry);
    final regionSpots = filteredForRegion(countrySpots, _selectedRegion);
    final areaSpots = filteredForArea(regionSpots, _selectedArea);
    if (_searchQuery.isEmpty) return areaSpots;
    return areaSpots.where((spot) => _matchesSpot(spot, _searchQuery)).toList();
  }

  List<SpotModel> filteredForCountry(List<SpotModel> items, String country) {
    if (country == _allCountriesLabel) return items;
    return items.where((spot) => spot.country == country).toList();
  }

  List<SpotModel> filteredForRegion(List<SpotModel> items, String region) {
    if (region == _allRegionsLabel) return items;
    return items.where((spot) => spot.region == region).toList();
  }

  List<SpotModel> filteredForArea(List<SpotModel> items, String area) {
    if (area == _allAreasLabel) return items;
    return items.where((spot) => _locationAreaForSpot(spot) == area).toList();
  }

  bool _matchesSpot(SpotModel spot, String query) {
    final q = query.toLowerCase();
    return spot.name.toLowerCase().contains(q) ||
        spot.area.toLowerCase().contains(q) ||
        spot.region.toLowerCase().contains(q) ||
        spot.country.toLowerCase().contains(q);
  }

  LatLng _centerOf(List<SpotModel> spots) {
    final lat =
        spots.map((spot) => spot.latitude).reduce((a, b) => a + b) /
        spots.length;
    final lng =
        spots.map((spot) => spot.longitude).reduce((a, b) => a + b) /
        spots.length;
    return LatLng(lat, lng);
  }

  Color _difficultyColor(String difficulty) {
    switch (difficulty) {
      case 'beginner':
        return const Color(0xFF4BAF74);
      case 'intermediate':
        return const Color(0xFFF1A24B);
      case 'advanced':
        return _mapMarkerBlue;
      default:
        return _mapMarkerBlueDark;
    }
  }

  List<Widget> _buildResultList({
    required BuildContext context,
    required List<SpotModel> visibleSpots,
    required Set<String> favoriteSpotIds,
    required SpotModel? selectedSpot,
  }) {
    if (_selectedCountry == _allCountriesLabel) {
      final countries = <String, List<SpotModel>>{};
      for (final spot in visibleSpots) {
        countries.putIfAbsent(spot.country, () => []).add(spot);
      }
      final entries = countries.entries.toList()
        ..sort(_compareGroupedEntries);
      return entries
          .map(
            (entry) => _ResultGroupCard(
              title: entry.key,
              subtitle: _groupSubtitle(entry.value.length, 'break'),
              children: _buildRegionGroups(
                context: context,
                spots: entry.value,
                favoriteSpotIds: favoriteSpotIds,
                selectedSpot: selectedSpot,
              ),
            ),
          )
          .toList();
    }

    if (_selectedRegion == _allRegionsLabel) {
      final regions = <String, List<SpotModel>>{};
      for (final spot in visibleSpots) {
        regions.putIfAbsent(spot.region, () => []).add(spot);
      }
      final entries = regions.entries.toList()
        ..sort(_compareGroupedEntries);
      return entries
          .map(
            (entry) => _ResultGroupCard(
              title: entry.key,
              subtitle: _groupSubtitle(entry.value.length, 'break'),
              children: _buildAreaGroups(
                context: context,
                spots: entry.value,
                favoriteSpotIds: favoriteSpotIds,
                selectedSpot: selectedSpot,
              ),
            ),
          )
          .toList();
    }

    if (_selectedArea == _allAreasLabel) {
      final areas = <String, List<SpotModel>>{};
      for (final spot in visibleSpots) {
        areas.putIfAbsent(_locationAreaForSpot(spot), () => []).add(spot);
      }
      final entries = areas.entries.toList()
        ..sort(_compareGroupedEntries);
      if (entries.length > 1) {
        return entries
            .map(
              (entry) => _ResultGroupCard(
                title: entry.key,
                subtitle: _groupSubtitle(entry.value.length, 'break'),
                children: _buildSpotTiles(
                  context: context,
                  spots: entry.value,
                  favoriteSpotIds: favoriteSpotIds,
                  selectedSpot: selectedSpot,
                ),
              ),
            )
            .toList();
      }
    }

    return _buildSpotTiles(
      context: context,
      spots: visibleSpots,
      favoriteSpotIds: favoriteSpotIds,
      selectedSpot: selectedSpot,
    );
  }

  List<Widget> _buildRegionGroups({
    required BuildContext context,
    required List<SpotModel> spots,
    required Set<String> favoriteSpotIds,
    required SpotModel? selectedSpot,
  }) {
    final regions = <String, List<SpotModel>>{};
    for (final spot in spots) {
      regions.putIfAbsent(spot.region, () => []).add(spot);
    }
    final entries = regions.entries.toList()..sort(_compareGroupedEntries);
    return entries
        .map(
          (entry) => _NestedResultGroupCard(
            title: entry.key,
            subtitle: _groupSubtitle(entry.value.length, 'break'),
            children: _buildAreaGroups(
              context: context,
              spots: entry.value,
              favoriteSpotIds: favoriteSpotIds,
              selectedSpot: selectedSpot,
            ),
          ),
        )
        .toList();
  }

  List<Widget> _buildAreaGroups({
    required BuildContext context,
    required List<SpotModel> spots,
    required Set<String> favoriteSpotIds,
    required SpotModel? selectedSpot,
  }) {
    final areas = <String, List<SpotModel>>{};
    for (final spot in spots) {
      areas.putIfAbsent(_locationAreaForSpot(spot), () => []).add(spot);
    }
    final entries = areas.entries.toList()..sort(_compareGroupedEntries);
    if (entries.length == 1) {
      return _buildSpotTiles(
        context: context,
        spots: entries.first.value,
        favoriteSpotIds: favoriteSpotIds,
        selectedSpot: selectedSpot,
      );
    }
    return entries
        .map(
          (entry) => _NestedResultGroupCard(
            title: entry.key,
            subtitle: _groupSubtitle(entry.value.length, 'break'),
            children: _buildSpotTiles(
              context: context,
              spots: entry.value,
              favoriteSpotIds: favoriteSpotIds,
              selectedSpot: selectedSpot,
            ),
          ),
        )
        .toList();
  }

  List<Widget> _buildSpotTiles({
    required BuildContext context,
    required List<SpotModel> spots,
    required Set<String> favoriteSpotIds,
    required SpotModel? selectedSpot,
  }) {
    return spots.map((spot) {
      final isSelected = spot.id == selectedSpot?.id;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Card(
          color: isSelected ? const Color(0xFFE6F3F1) : null,
          child: ListTile(
            title: Text(spot.name),
            subtitle: Text(
              '${spot.area}, ${spot.region}\n${spot.waveHeightM}m • ${spot.difficulty}',
            ),
            isThreeLine: true,
            trailing: Icon(
              favoriteSpotIds.contains(spot.id)
                  ? Icons.favorite
                  : Icons.chevron_right,
              color: favoriteSpotIds.contains(spot.id) ? _favoriteAccent : null,
            ),
            onTap: () => context.push('/spot/${spot.id}'),
            onLongPress: () => _focusSpot(spot),
          ),
        ),
      );
    }).toList();
  }
}

String _groupSubtitle(int count, String label) {
  return '$count ${count == 1 ? label : '${label}s'}';
}

int _compareGroupedEntries(
  MapEntry<String, List<SpotModel>> a,
  MapEntry<String, List<SpotModel>> b,
) {
  final countCompare = b.value.length.compareTo(a.value.length);
  if (countCompare != 0) return countCompare;
  return a.key.compareTo(b.key);
}

int Function(String a, String b) _compareGroupedKeysByCount(
  Map<String, List<SpotModel>> groups,
) {
  return (a, b) {
    final countCompare = groups[b]!.length.compareTo(groups[a]!.length);
    if (countCompare != 0) return countCompare;
    return a.compareTo(b);
  };
}

String _locationAreaForSpot(SpotModel spot) {
  if (spot.country == 'Indonesia' && spot.region == 'Bali') {
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
    }
  }
  return spot.area;
}

class _LocationSelection {
  const _LocationSelection({
    required this.country,
    required this.region,
    required this.area,
    this.spotId,
  });

  final String country;
  final String region;
  final String area;
  final String? spotId;
}

class _MapCanvas extends StatelessWidget {
  const _MapCanvas({
    required this.mapController,
    required this.spots,
    required this.initialCenter,
    required this.initialZoom,
    required this.selectedSpotId,
    required this.onSpotTap,
    required this.onPositionChanged,
  });

  final MapController mapController;
  final List<SpotModel> spots;
  final LatLng initialCenter;
  final double initialZoom;
  final String? selectedSpotId;
  final ValueChanged<SpotModel> onSpotTap;
  final void Function(MapCamera, bool) onPositionChanged;

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: initialCenter,
        initialZoom: initialZoom,
        minZoom: 2,
        maxZoom: 12,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all,
        ),
        onPositionChanged: onPositionChanged,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.mobile_flutter',
        ),
        MarkerLayer(
          markers: spots
              .map(
                (spot) => Marker(
                  point: LatLng(spot.latitude, spot.longitude),
                  width: selectedSpotId == spot.id ? 120 : 22,
                  height: selectedSpotId == spot.id ? 92 : 22,
                  child: GestureDetector(
                    onTap: () => onSpotTap(spot),
                    child: _SpotMarker(
                      spot: spot,
                      isSelected: selectedSpotId == spot.id,
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class _LocationPickerField extends StatelessWidget {
  const _LocationPickerField({
    required this.sourceItems,
    required this.favoriteSpotIds,
    required this.selectedCountry,
    required this.selectedRegion,
    required this.selectedArea,
    required this.selectedSpotId,
    required this.onChanged,
  });

  final List<SpotModel> sourceItems;
  final Set<String> favoriteSpotIds;
  final String selectedCountry;
  final String selectedRegion;
  final String selectedArea;
  final String? selectedSpotId;
  final ValueChanged<_LocationSelection> onChanged;

  @override
  Widget build(BuildContext context) {
    final path = <String>[
      selectedCountry,
      if (selectedRegion != _allRegionsLabel) selectedRegion,
      if (selectedArea != _allAreasLabel) selectedArea,
    ];
    if (selectedSpotId != null) {
      final selectedSpot = sourceItems.where((spot) => spot.id == selectedSpotId);
      if (selectedSpot.isNotEmpty) {
        path.add(selectedSpot.first.name);
      }
    }

    return InkWell(
      onTap: () async {
        final selection = await showModalBottomSheet<_LocationSelection>(
          context: context,
          isScrollControlled: true,
          builder: (context) => _LocationPickerSheet(
            sourceItems: sourceItems,
            favoriteSpotIds: favoriteSpotIds,
            selectedCountry: selectedCountry,
            selectedRegion: selectedRegion,
            selectedArea: selectedArea,
            selectedSpotId: selectedSpotId,
          ),
        );
        if (selection == null) return;
        onChanged(selection);
      },
      borderRadius: BorderRadius.circular(16),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Location',
          suffixIcon: Icon(Icons.keyboard_arrow_down),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(path.last),
            const SizedBox(height: 2),
            Text(
              path.join(' • '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationPickerSheet extends StatelessWidget {
  const _LocationPickerSheet({
    required this.sourceItems,
    required this.favoriteSpotIds,
    required this.selectedCountry,
    required this.selectedRegion,
    required this.selectedArea,
    required this.selectedSpotId,
  });

  final List<SpotModel> sourceItems;
  final Set<String> favoriteSpotIds;
  final String selectedCountry;
  final String selectedRegion;
  final String selectedArea;
  final String? selectedSpotId;

  @override
  Widget build(BuildContext context) {
    final countryGroups = <String, List<SpotModel>>{};
    for (final spot in sourceItems) {
      countryGroups.putIfAbsent(spot.country, () => []).add(spot);
    }
    final countries = <String>[
      _allCountriesLabel,
      ...countryGroups.keys.toList()..sort(_compareGroupedKeysByCount(countryGroups)),
    ];

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.82,
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
            Text(
              'Choose location',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            _LocationActionTile(
              title: _allCountriesLabel,
              subtitle: '${sourceItems.length} breaks across the map',
              selected:
                  selectedCountry == _allCountriesLabel &&
                  selectedRegion == _allRegionsLabel &&
                  selectedArea == _allAreasLabel &&
                  selectedSpotId == null,
              onTap: () => Navigator.of(context).pop(
                const _LocationSelection(
                  country: _allCountriesLabel,
                  region: _allRegionsLabel,
                  area: _allAreasLabel,
                ),
              ),
            ),
            const SizedBox(height: 12),
            ...countries
                .where((country) => country != _allCountriesLabel)
                .map(
                  (country) => _CountryLocationSection(
                    country: country,
                    spots: sourceItems
                        .where((spot) => spot.country == country)
                        .toList(),
                    favoriteSpotIds: favoriteSpotIds,
                    selectedCountry: selectedCountry,
                    selectedRegion: selectedRegion,
                    selectedArea: selectedArea,
                    selectedSpotId: selectedSpotId,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _CountryLocationSection extends StatelessWidget {
  const _CountryLocationSection({
    required this.country,
    required this.spots,
    required this.favoriteSpotIds,
    required this.selectedCountry,
    required this.selectedRegion,
    required this.selectedArea,
    required this.selectedSpotId,
  });

  final String country;
  final List<SpotModel> spots;
  final Set<String> favoriteSpotIds;
  final String selectedCountry;
  final String selectedRegion;
  final String selectedArea;
  final String? selectedSpotId;

  @override
  Widget build(BuildContext context) {
    final regionMap = <String, List<SpotModel>>{};
    for (final spot in spots) {
      regionMap.putIfAbsent(spot.region, () => []).add(spot);
    }
    final regions = regionMap.entries.toList()..sort(_compareGroupedEntries);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: selectedCountry == country,
        title: Text(country),
        subtitle: Text('${spots.length} breaks'),
        children: [
          _LocationActionTile(
            title: 'See all $country',
            subtitle: '${spots.length} breaks',
            selected:
                selectedCountry == country &&
                selectedRegion == _allRegionsLabel &&
                selectedArea == _allAreasLabel &&
                selectedSpotId == null,
            onTap: () => Navigator.of(context).pop(
              _LocationSelection(
                country: country,
                region: _allRegionsLabel,
                area: _allAreasLabel,
              ),
            ),
          ),
          ...regions.map(
            (entry) => _RegionLocationSection(
              country: country,
              region: entry.key,
              spots: entry.value,
              favoriteSpotIds: favoriteSpotIds,
              selectedCountry: selectedCountry,
              selectedRegion: selectedRegion,
              selectedArea: selectedArea,
              selectedSpotId: selectedSpotId,
            ),
          ),
        ],
      ),
    );
  }
}

class _RegionLocationSection extends StatelessWidget {
  const _RegionLocationSection({
    required this.country,
    required this.region,
    required this.spots,
    required this.favoriteSpotIds,
    required this.selectedCountry,
    required this.selectedRegion,
    required this.selectedArea,
    required this.selectedSpotId,
  });

  final String country;
  final String region;
  final List<SpotModel> spots;
  final Set<String> favoriteSpotIds;
  final String selectedCountry;
  final String selectedRegion;
  final String selectedArea;
  final String? selectedSpotId;

  @override
  Widget build(BuildContext context) {
    final areaMap = <String, List<SpotModel>>{};
    for (final spot in spots) {
      areaMap.putIfAbsent(_locationAreaForSpot(spot), () => []).add(spot);
    }
    final areas = areaMap.entries.toList()..sort(_compareGroupedEntries);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF6F3ED),
          borderRadius: BorderRadius.circular(16),
        ),
        child: ExpansionTile(
          initiallyExpanded:
              selectedCountry == country && selectedRegion == region,
          title: Text(region),
          subtitle: Text('${spots.length} breaks'),
          children: [
            _LocationActionTile(
              title: 'See all $region',
              subtitle: '${spots.length} breaks',
              selected:
                  selectedCountry == country &&
                  selectedRegion == region &&
                  selectedArea == _allAreasLabel &&
                  selectedSpotId == null,
              onTap: () => Navigator.of(context).pop(
                _LocationSelection(
                  country: country,
                  region: region,
                  area: _allAreasLabel,
                ),
              ),
            ),
            ...areas.map(
              (entry) => _AreaLocationSection(
                country: country,
                region: region,
                area: entry.key,
                spots: entry.value,
                favoriteSpotIds: favoriteSpotIds,
                selectedCountry: selectedCountry,
                selectedRegion: selectedRegion,
                selectedArea: selectedArea,
                selectedSpotId: selectedSpotId,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AreaLocationSection extends StatelessWidget {
  const _AreaLocationSection({
    required this.country,
    required this.region,
    required this.area,
    required this.spots,
    required this.favoriteSpotIds,
    required this.selectedCountry,
    required this.selectedRegion,
    required this.selectedArea,
    required this.selectedSpotId,
  });

  final String country;
  final String region;
  final String area;
  final List<SpotModel> spots;
  final Set<String> favoriteSpotIds;
  final String selectedCountry;
  final String selectedRegion;
  final String selectedArea;
  final String? selectedSpotId;

  @override
  Widget build(BuildContext context) {
    final favorites = spots.where((spot) => favoriteSpotIds.contains(spot.id)).toList();
    final nonFavorites = spots
        .where((spot) => !favoriteSpotIds.contains(spot.id))
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: ExpansionTile(
          initiallyExpanded:
              selectedCountry == country &&
              selectedRegion == region &&
              selectedArea == area,
          title: Text(area),
          subtitle: Text('${spots.length} breaks'),
          children: [
            if (spots.length > 1)
              _LocationActionTile(
                title: 'See all $area',
                subtitle: '${spots.length} breaks',
                selected:
                    selectedCountry == country &&
                    selectedRegion == region &&
                    selectedArea == area &&
                    selectedSpotId == null,
                onTap: () => Navigator.of(context).pop(
                  _LocationSelection(
                    country: country,
                    region: region,
                    area: area,
                  ),
                ),
              ),
            if (favorites.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Favorites'),
                ),
              ),
              ...favorites.map(
                (spot) => _SpotLocationTile(
                  spot: spot,
                  selected: selectedSpotId == spot.id,
                ),
              ),
            ],
            ...nonFavorites.map(
              (spot) => _SpotLocationTile(
                spot: spot,
                selected: selectedSpotId == spot.id,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationActionTile extends StatelessWidget {
  const _LocationActionTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: selected ? const Icon(Icons.check_circle) : null,
      onTap: onTap,
    );
  }
}

class _SpotLocationTile extends StatelessWidget {
  const _SpotLocationTile({
    required this.spot,
    required this.selected,
  });

  final SpotModel spot;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      title: Text(spot.name),
      subtitle: Text('${spot.area}, ${spot.region}'),
      trailing: selected ? const Icon(Icons.check_circle) : null,
      onTap: () => Navigator.of(context).pop(
        _LocationSelection(
          country: spot.country,
          region: spot.region,
          area: _locationAreaForSpot(spot),
          spotId: spot.id,
        ),
      ),
    );
  }
}

class _ResultGroupCard extends StatelessWidget {
  const _ResultGroupCard({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          title: Text(title),
          subtitle: Text(subtitle),
          childrenPadding: const EdgeInsets.only(bottom: 6),
          children: children,
        ),
      ),
    );
  }
}

class _NestedResultGroupCard extends StatelessWidget {
  const _NestedResultGroupCard({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFF6F3ED),
          borderRadius: BorderRadius.circular(16),
        ),
        child: ExpansionTile(
          title: Text(title),
          subtitle: Text(subtitle),
          childrenPadding: const EdgeInsets.only(bottom: 6),
          children: children,
        ),
      ),
    );
  }
}

class _SpotMarker extends StatelessWidget {
  const _SpotMarker({required this.spot, required this.isSelected});

  final SpotModel spot;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    if (!isSelected) {
      return Center(
        child: Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
            color: _mapMarkerBlue,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: _mapMarkerBlueDark,
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 10,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            spot.name,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 4),
        const Icon(
          Icons.place_rounded,
          color: _mapMarkerBlue,
          size: 40,
        ),
      ],
    );
  }
}
