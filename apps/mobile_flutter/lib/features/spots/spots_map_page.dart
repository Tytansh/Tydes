import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import 'spots_page.dart';

class SpotsMapPage extends ConsumerStatefulWidget {
  const SpotsMapPage({super.key});

  @override
  ConsumerState<SpotsMapPage> createState() => _SpotsMapPageState();
}

class _SpotsMapPageState extends ConsumerState<SpotsMapPage> {
  final MapController _mapController = MapController();
  String _selectedArea = 'All Southeast Asia';
  String? _selectedSpotId;
  double _zoom = 3.2;
  bool _savedOnly = false;

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

          if (sourceItems.isEmpty) {
            return Center(
              child: Text(
                _savedOnly
                    ? 'No saved spots to show on the map yet.'
                    : 'No spots available yet.',
              ),
            );
          }

          final areas = <String>{
            'All Southeast Asia',
            ...sourceItems.map((spot) => '${spot.area}, ${spot.region}'),
          }.toList();

          final filteredSpots = _selectedArea == 'All Southeast Asia'
              ? sourceItems
              : sourceItems
                    .where(
                      (spot) => '${spot.area}, ${spot.region}' == _selectedArea,
                    )
                    .toList();

          final selectedSpot = filteredSpots.firstWhere(
            (spot) => spot.id == _selectedSpotId,
            orElse: () => filteredSpots.first,
          );

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
                                  _selectedArea = 'All Southeast Asia';
                                  _selectedSpotId = null;
                                });
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  _showArea(
                                    value
                                        ? items
                                              .where(
                                                (spot) => favoriteSpotIds
                                                    .contains(spot.id),
                                              )
                                              .toList()
                                        : items,
                                  );
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: areas.contains(_selectedArea)
                          ? _selectedArea
                          : areas.first,
                      decoration: InputDecoration(
                        labelText: 'Area',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      items: areas
                          .map(
                            (area) => DropdownMenuItem<String>(
                              value: area,
                              child: Text(area),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _selectedArea = value;
                          _selectedSpotId = null;
                        });
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          _showArea(filteredFor(sourceItems, value));
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue:
                          filteredSpots.any(
                            (spot) => spot.id == _selectedSpotId,
                          )
                          ? _selectedSpotId
                          : filteredSpots.first.id,
                      decoration: InputDecoration(
                        labelText: 'Beach / break',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      items: filteredSpots
                          .map(
                            (spot) => DropdownMenuItem<String>(
                              value: spot.id,
                              child: Text(spot.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        final spot = filteredSpots.firstWhere(
                          (item) => item.id == value,
                        );
                        _focusSpot(spot);
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Use normal map gestures on iPhone: pinch to zoom, drag to pan. On Mac, use trackpad pinch or scroll.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
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
                      spots: filteredSpots,
                      initialCenter: _centerOf(filteredSpots),
                      initialZoom: _selectedArea == 'All Southeast Asia'
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
                                ? const Color(0xFFCF4A3B)
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
              ),
              ...filteredSpots.map((spot) {
                final isSelected = spot.id == selectedSpot.id;
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
                        color: favoriteSpotIds.contains(spot.id)
                            ? const Color(0xFFCF4A3B)
                            : null,
                      ),
                      onTap: () => context.push('/spot/${spot.id}'),
                      onLongPress: () => _focusSpot(spot),
                    ),
                  ),
                );
              }),
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
      _selectedArea = '${spot.area}, ${spot.region}';
    });
  }

  void _showArea(List<SpotModel> spots) {
    if (spots.length == 1) {
      _focusSpot(spots.first, zoom: 9.2);
      return;
    }
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
      _selectedSpotId = spots.first.id;
      _zoom = _mapController.camera.zoom;
    });
  }

  List<SpotModel> filteredFor(List<SpotModel> items, String area) {
    if (area == 'All Southeast Asia') return items;
    return items
        .where((spot) => '${spot.area}, ${spot.region}' == area)
        .toList();
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
        return const Color(0xFFCF4A3B);
      default:
        return const Color(0xFF0B6E6E);
    }
  }
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
                  width: 120,
                  height: 92,
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

class _SpotMarker extends StatelessWidget {
  const _SpotMarker({required this.spot, required this.isSelected});

  final SpotModel spot;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF0B6E6E) : Colors.white,
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
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: isSelected ? Colors.white : const Color(0xFF16333A),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Icon(
          Icons.location_on,
          color: isSelected ? const Color(0xFF0B6E6E) : const Color(0xFFCF4A3B),
          size: isSelected ? 38 : 34,
        ),
      ],
    );
  }
}
