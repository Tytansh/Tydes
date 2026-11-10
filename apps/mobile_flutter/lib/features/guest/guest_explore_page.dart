import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_error_message.dart';
import '../../core/network/public_preview_models.dart';
import '../../core/network/surf_repository.dart';
import '../auth/auth_return_path.dart';
import '../social/social_profile.dart';
import '../spots/map_tile_config.dart' as tiles;

final guestSpotsProvider =
    FutureProvider.autoDispose<List<PublicMapSpotPreview>>((ref) {
      final link = ref.keepAlive();
      final timer = Timer(const Duration(minutes: 10), link.close);
      ref.onDispose(timer.cancel);
      return ref.watch(surfRepositoryProvider).fetchPublicSpots();
    });
final guestEventsProvider =
    FutureProvider.autoDispose<List<PublicEventPreview>>((ref) {
      final link = ref.keepAlive();
      final timer = Timer(const Duration(minutes: 2), link.close);
      ref.onDispose(timer.cancel);
      return ref.watch(surfRepositoryProvider).fetchPublicEvents();
    });

enum GuestSection {
  spots('Spots', '/explore', Icons.waves_outlined),
  map('Map', '/explore/map', Icons.map_outlined),
  events('Events', '/explore/events', Icons.event_outlined);

  const GuestSection(this.label, this.path, this.icon);
  final String label, path;
  final IconData icon;
}

enum _GuestNavigationItem {
  feed('Feed', Icons.home_outlined, account: AccountDestination.feed),
  spots('Spots', Icons.waves_outlined, section: GuestSection.spots),
  map('Map', Icons.map_outlined, section: GuestSection.map),
  events('Events', Icons.event_outlined, section: GuestSection.events),
  profile('Profile', Icons.person_outline, account: AccountDestination.profile);

  const _GuestNavigationItem(
    this.label,
    this.icon, {
    this.section,
    this.account,
  });
  final String label;
  final IconData icon;
  final GuestSection? section;
  final AccountDestination? account;
}

bool guestSpotMatches(
  PublicSpotPreview spot, {
  String country = '',
  String region = '',
  String query = '',
}) {
  final q = query.trim().toLowerCase();
  return (country.isEmpty || spot.country == country) &&
      (region.isEmpty || spot.region == region) &&
      (q.isEmpty ||
          [
            spot.name,
            spot.area,
            spot.region,
            spot.country,
          ].any((s) => s.toLowerCase().contains(q)));
}

bool guestEventMatches(
  PublicEventPreview event, {
  String country = '',
  String region = '',
  String query = '',
}) {
  final spot = event.spot;
  final q = query.trim().toLowerCase();
  return !event.ended &&
      (country.isEmpty || spot?.country == country) &&
      (region.isEmpty || spot?.region == region) &&
      (q.isEmpty ||
          [
            event.body,
            event.hostName,
            event.hostHandle ?? '',
            spot?.name ?? '',
            spot?.area ?? '',
            spot?.region ?? '',
            spot?.country ?? '',
          ].any((s) => s.toLowerCase().contains(q)));
}

class GuestExplorePage extends ConsumerStatefulWidget {
  const GuestExplorePage({super.key, required this.section});
  final GuestSection section;
  @override
  ConsumerState<GuestExplorePage> createState() => _GuestExplorePageState();
}

class _GuestExplorePageState extends ConsumerState<GuestExplorePage> {
  final _search = TextEditingController();
  String _country = '', _region = '';
  int _visibleCount = 40;
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _signIn() => context.go(loginForPath(widget.section.path));

  void _openNavigation(_GuestNavigationItem item) {
    if (item.section != null) {
      context.go(item.section!.path);
    } else {
      context.go(loginForPath(widget.section.path, destination: item.account));
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 980;
    // Deliberately no account, feed, alerts, favorites, forecasts or social-state providers.
    final spots = ref.watch(guestSpotsProvider);
    final events = widget.section == GuestSection.events
        ? ref.watch(guestEventsProvider)
        : null;
    final content = SafeArea(
      child: Column(
        children: [
          if (desktop)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Explore Tydes',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  TextButton(onPressed: _signIn, child: const Text('Sign in')),
                ],
              ),
            ),
          Expanded(
            child: spots.when(
              data: (items) => _content(items, events),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _LoadFailure(
                error: error,
                retry: () => ref.invalidate(guestSpotsProvider),
              ),
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      appBar: desktop
          ? null
          : AppBar(
              title: const _Brand(),
              actions: [
                TextButton(onPressed: _signIn, child: const Text('Sign in')),
              ],
            ),
      body: desktop
          ? Row(
              children: [
                Container(
                  width: 208,
                  color: const Color(0xFF194E53),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 26, 18, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _Brand(light: true),
                          const SizedBox(height: 14),
                          const Text(
                            'GUEST EXPLORER',
                            style: TextStyle(
                              color: Color(0xFFBCE7E3),
                              fontSize: 11,
                              letterSpacing: 1.5,
                            ),
                          ),
                          const SizedBox(height: 28),
                          for (final item in _GuestNavigationItem.values)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Material(
                                color: widget.section == item.section
                                    ? const Color(0xFFBFE9E5)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(16),
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  selected: widget.section == item.section,
                                  selectedTileColor: const Color(0xFFBFE9E5),
                                  selectedColor: const Color(0xFF103E43),
                                  textColor: Colors.white,
                                  iconColor: Colors.white70,
                                  leading: Icon(item.icon),
                                  title: Text(item.label),
                                  trailing: item.account == null
                                      ? null
                                      : const Icon(
                                          Icons.lock_outline,
                                          size: 14,
                                          color: Colors.white70,
                                        ),
                                  onTap: () => _openNavigation(item),
                                ),
                              ),
                            ),
                          const Spacer(),
                          const Text(
                            'Find your spot. Meet your crew.',
                            style: TextStyle(color: Colors.white, height: 1.5),
                          ),
                          const SizedBox(height: 14),
                          FilledButton(
                            onPressed: _signIn,
                            child: const Text('Sign in'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(child: content),
              ],
            )
          : content,
      bottomNavigationBar: desktop
          ? null
          : NavigationBar(
              selectedIndex: _GuestNavigationItem.values.indexWhere(
                (item) => item.section == widget.section,
              ),
              onDestinationSelected: (index) =>
                  _openNavigation(_GuestNavigationItem.values[index]),
              destinations: [
                for (final item in _GuestNavigationItem.values)
                  NavigationDestination(
                    icon: Icon(item.icon),
                    label: item.label,
                  ),
              ],
            ),
    );
  }

  Widget _content(
    List<PublicMapSpotPreview> spots,
    AsyncValue<List<PublicEventPreview>>? events,
  ) {
    final countries = spots.map((s) => s.country).toSet().toList()..sort();
    final regions =
        spots
            .where((s) => _country.isEmpty || s.country == _country)
            .map((s) => s.region)
            .toSet()
            .toList()
          ..sort();
    final filtered = spots
        .where(
          (s) => guestSpotMatches(
            s,
            country: _country,
            region: _region,
            query: _search.text,
          ),
        )
        .toList();
    final eventTab = widget.section == GuestSection.events;
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1140),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE4F1EF),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eventTab
                            ? 'Find your next surf meetup'
                            : 'Where We Surfing',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Browse freely. Sign in to save spots, join events, post, and chat.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _search,
                  onChanged: (_) => setState(() => _visibleCount = 40),
                  decoration: InputDecoration(
                    labelText: eventTab
                        ? 'Search events, hosts or places'
                        : 'Search spots or places',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() {
                              _search.clear();
                              _visibleCount = 40;
                            }),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: constraints.maxWidth < 540
                            ? constraints.maxWidth
                            : (constraints.maxWidth - 12) / 2,
                        child: DropdownButtonFormField<String>(
                          key: ValueKey('country-$_country'),
                          initialValue: countries.contains(_country)
                              ? _country
                              : '',
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Country',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('All countries'),
                            ),
                            for (final country in countries)
                              DropdownMenuItem(
                                value: country,
                                child: Text(country),
                              ),
                          ],
                          onChanged: (value) => setState(() {
                            _country = value ?? '';
                            _region = '';
                            _visibleCount = 40;
                          }),
                        ),
                      ),
                      SizedBox(
                        width: constraints.maxWidth < 540
                            ? constraints.maxWidth
                            : (constraints.maxWidth - 12) / 2,
                        child: DropdownButtonFormField<String>(
                          key: ValueKey('region-$_country-$_region'),
                          initialValue: regions.contains(_region)
                              ? _region
                              : '',
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Region',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('All regions'),
                            ),
                            for (final region in regions)
                              DropdownMenuItem(
                                value: region,
                                child: Text(region),
                              ),
                          ],
                          onChanged: (value) => setState(() {
                            _region = value ?? '';
                            _visibleCount = 40;
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                if (eventTab)
                  events!.when(
                    data: (items) => _events(
                      items
                          .where(
                            (e) => guestEventMatches(
                              e,
                              country: _country,
                              region: _region,
                              query: _search.text,
                            ),
                          )
                          .toList(),
                    ),
                    loading: () => const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (error, _) => _LoadFailure(
                      error: error,
                      retry: () => ref.invalidate(guestEventsProvider),
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${filtered.length} surf spots',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh spots',
                        onPressed: () => ref.invalidate(guestSpotsProvider),
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  if (widget.section == GuestSection.map &&
                      filtered.isNotEmpty) ...[
                    _GuestMap(
                      key: ValueKey('$_country|$_region|${_search.text}'),
                      spots: filtered,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Tap a marker for the spot guide. Map data is not a live surf forecast.',
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (filtered.isEmpty)
                    const _Empty(
                      text:
                          'No spots match. Try another place or clear your filters.',
                    ),
                  for (final spot in filtered.take(_visibleCount))
                    Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        leading: const Icon(Icons.place_outlined),
                        title: Text(spot.name),
                        subtitle: Text(
                          '${spot.area}, ${spot.region}, ${spot.country}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push('/spot/${spot.id}'),
                      ),
                    ),
                  if (filtered.length > _visibleCount)
                    TextButton(
                      onPressed: () => setState(() => _visibleCount += 40),
                      child: const Text('Show more spots'),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _events(List<PublicEventPreview> events) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              'Upcoming public events',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: 'Refresh events',
            onPressed: () => ref.invalidate(guestEventsProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      if (events.isEmpty)
        const _Empty(
          text:
              'No upcoming public events here yet. Try another place or check back soon.',
        ),
      for (final event in events)
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.all(18),
            leading: TydesProfileAvatar(
              displayName: event.hostName,
              imageUrl: event.hostAvatarUrl,
              size: 42,
            ),
            title: Text(
              event.body.trim().isEmpty ? 'Surf meetup' : event.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${event.meetupDate == null ? 'Date to be confirmed' : DateFormat('MMM d, y').format(DateTime.parse(event.meetupDate!))}\n${event.spot?.name ?? 'Location to be confirmed'} · ${event.hostName}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/post/${event.id}'),
          ),
        ),
    ],
  );
}

class _Brand extends StatelessWidget {
  const _Brand({this.light = false});
  final bool light;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Image.asset(
          'assets/branding/tydes-wave-blue-256.png',
          width: 46,
          height: 46,
        ),
      ),
      const SizedBox(width: 10),
      Flexible(
        child: Text(
          'Tydes',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 24,
            color: light ? Colors.white : null,
          ),
        ),
      ),
    ],
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: const EdgeInsets.all(24), child: Text(text)),
  );
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.error, required this.retry});
  final Object error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(friendlyLoadErrorMessage(error, label: 'public information')),
          const SizedBox(height: 12),
          TextButton(onPressed: retry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}

class _GuestMap extends StatefulWidget {
  const _GuestMap({super.key, required this.spots});
  final List<PublicMapSpotPreview> spots;
  @override
  State<_GuestMap> createState() => _GuestMapState();
}

class _GuestMapState extends State<_GuestMap> {
  final _controller = MapController();
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final points = widget.spots
        .where(
          (s) =>
              s.latitude.isFinite &&
              s.longitude.isFinite &&
              s.latitude.abs() <= 90 &&
              s.longitude.abs() <= 180,
        )
        .toList();
    if (points.isEmpty) {
      return const _Empty(text: 'No mapped spots in this location.');
    }
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: math
            .min(560, constraints.maxWidth * .92)
            .clamp(320, 560)
            .toDouble(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: LatLng(
                points.first.latitude,
                points.first.longitude,
              ),
              initialZoom: 4,
              minZoom: 2,
              maxZoom: 13,
              initialCameraFit: CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(
                  points.map((s) => LatLng(s.latitude, s.longitude)).toList(),
                ),
                padding: const EdgeInsets.all(40),
                maxZoom: 10,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: tiles.mapTileUrlTemplate,
                userAgentPackageName: tiles.mapTileUserAgent,
              ),
              MarkerLayer(
                markers: [
                  for (final spot in points)
                    Marker(
                      width: 36,
                      height: 36,
                      point: LatLng(spot.latitude, spot.longitude),
                      child: Tooltip(
                        message: spot.name,
                        child: IconButton(
                          tooltip: spot.name,
                          padding: EdgeInsets.zero,
                          onPressed: () => context.push('/spot/${spot.id}'),
                          icon: Icon(
                            Icons.location_on,
                            size: 32,
                            color: spot.difficulty == 'beginner'
                                ? const Color(0xFF4BAF74)
                                : spot.difficulty == 'advanced'
                                ? const Color(0xFFD75A4A)
                                : const Color(0xFF2E8FE8),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution(
                    tiles.mapAttributionLabel,
                    onTap: () => launchUrl(
                      Uri.parse(tiles.mapAttributionUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
