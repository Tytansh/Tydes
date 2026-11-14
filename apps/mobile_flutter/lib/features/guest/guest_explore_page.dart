import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_error_message.dart';
import '../../core/legal/legal_links.dart';
import '../../core/network/public_preview_models.dart';
import '../../core/network/surf_repository.dart';
import '../auth/auth_return_path.dart';
import '../social/social_profile.dart';
import '../spots/map_tile_config.dart' as tiles;
import '../spots/map_pinch_gestures.dart';
import '../spots/surf_map_markers.dart';

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
// Each map owns its tile provider; tests can supply in-memory tiles.
final guestTileProviderFactory = Provider<TileProvider Function()>(
  (ref) =>
      () => NetworkTileProvider(),
);

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

bool _mapped(PublicMapSpotPreview spot) =>
    spot.latitude.isFinite &&
    spot.longitude.isFinite &&
    spot.latitude.abs() <= 90 &&
    spot.longitude.abs() <= 180;

// Editorial picks from the existing catalog, not live surf recommendations.
const guestPopularSpotIds = [
  'spot_padang_padang',
  'spot_surfers_point',
  'spot_siargao',
  'spot_arugam',
  'spot_jinzun_harbor',
  'spot_kata',
  'spot_cherating',
  'spot_uluwatu_peak',
];

List<PublicMapSpotPreview> guestBrowseSpots(
  List<PublicMapSpotPreview> visible, {
  required bool popularOnly,
}) {
  final byId = {for (final spot in visible) spot.id: spot};
  if (popularOnly) {
    return [
      for (final id in guestPopularSpotIds)
        if (byId[id] != null) byId[id]!,
    ];
  }
  final ranked = [...visible];
  int rank(PublicMapSpotPreview spot) {
    final index = guestPopularSpotIds.indexOf(spot.id);
    return index < 0 ? guestPopularSpotIds.length : index;
  }

  ranked.sort((a, b) {
    final order = rank(a).compareTo(rank(b));
    return order != 0 ? order : a.name.compareTo(b.name);
  });
  return ranked;
}

class GuestMapEventGroup {
  const GuestMapEventGroup({required this.spot, required this.events});
  final PublicMapSpotPreview spot;
  final List<PublicEventPreview> events;
}

List<GuestMapEventGroup> buildGuestEventGroups({
  required List<PublicMapSpotPreview> spots,
  required List<PublicEventPreview> events,
  required DateTime now,
  String country = '',
  String region = '',
  String query = '',
}) {
  final byId = {for (final spot in spots.where(_mapped)) spot.id: spot};
  final today = DateUtils.dateOnly(now);
  final groups = <String, List<PublicEventPreview>>{};
  for (final event in events) {
    final spot = byId[event.spot?.id];
    final start = DateTime.tryParse(event.meetupDate ?? '');
    final end = DateTime.tryParse(event.meetupEndDate ?? '') ?? start;
    if (spot == null ||
        start == null ||
        end == null ||
        end.isBefore(start) ||
        DateUtils.dateOnly(end).isBefore(today) ||
        !guestEventMatches(
          event,
          country: country,
          region: region,
          query: query,
        )) {
      continue;
    }
    groups.putIfAbsent(spot.id, () => []).add(event);
  }
  for (final items in groups.values) {
    items.sort((a, b) => a.meetupDate!.compareTo(b.meetupDate!));
  }
  return [
    for (final entry in groups.entries)
      GuestMapEventGroup(spot: byId[entry.key]!, events: entry.value),
  ];
}

class GuestExplorePage extends ConsumerStatefulWidget {
  const GuestExplorePage({super.key});
  @override
  ConsumerState<GuestExplorePage> createState() => _GuestExplorePageState();
}

class _GuestExplorePageState extends ConsumerState<GuestExplorePage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _country = '', _region = '';
  bool _showEvents = true;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Only explicitly public data. Never mount feed, forecast, attendee or chat providers.
    final spots = ref.watch(guestSpotsProvider);
    final events = _showEvents ? ref.watch(guestEventsProvider) : null;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                'assets/branding/tydes-wave-blue-256.png',
                width: 42,
                height: 42,
              ),
            ),
            const SizedBox(width: 10),
            const Text('TYDES', style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => context.go(loginForPath('/explore')),
            child: const Text('Sign in'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: spots.when(
          data: (items) => _workspace(items, events),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: _failure(error, () => ref.invalidate(guestSpotsProvider)),
          ),
        ),
      ),
    );
  }

  Widget _failure(Object error, VoidCallback retry) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(friendlyLoadErrorMessage(error, label: 'public information')),
        TextButton(onPressed: retry, child: const Text('Retry')),
      ],
    ),
  );

  Widget _workspace(
    List<PublicMapSpotPreview> all,
    AsyncValue<List<PublicEventPreview>>? events,
  ) {
    final countries = all.map((s) => s.country).toSet().toList()..sort();
    final regions =
        all
            .where((s) => _country.isEmpty || s.country == _country)
            .map((s) => s.region)
            .toSet()
            .toList()
          ..sort();
    final validEvents = events == null || events.hasError || events.isLoading
        ? <PublicEventPreview>[]
        : events.valueOrNull ?? <PublicEventPreview>[];
    final groups = _showEvents
        ? buildGuestEventGroups(
            spots: all,
            events: validEvents,
            now: DateTime.now(),
            country: _country,
            region: _region,
            query: _search.text,
          )
        : <GuestMapEventGroup>[];
    final eventSpotIds = groups.map((g) => g.spot.id).toSet();
    final visible = all
        .where(
          (s) =>
              _mapped(s) &&
              guestSpotMatches(s, country: _country, region: _region) &&
              (guestSpotMatches(s, query: _search.text) ||
                  eventSpotIds.contains(s.id)),
        )
        .toList();
    final count = groups.fold<int>(
      0,
      (count, group) => count + group.events.length,
    );
    final popularOnly =
        _country.isEmpty && _region.isEmpty && _search.text.trim().isEmpty;
    final browseSpots = guestBrowseSpots(visible, popularOnly: popularOnly);
    final listTitle = popularOnly
        ? 'Popular spots'
        : _search.text.trim().isNotEmpty
        ? 'Matching spots'
        : 'Spots in ${_region.isNotEmpty ? _region : _country}';
    final controls = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Surf map',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                ),
              ),
              const Text('Show events'),
              const SizedBox(width: 8),
              Switch(
                value: _showEvents,
                onChanged: (value) => setState(() => _showEvents = value),
              ),
            ],
          ),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Search spots, events or places',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(_search.clear),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('country-$_country'),
                  initialValue: countries.contains(_country) ? _country : '',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Country'),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('All countries'),
                    ),
                    for (final country in countries)
                      DropdownMenuItem(value: country, child: Text(country)),
                  ],
                  onChanged: (value) => setState(() {
                    _country = value ?? '';
                    _region = '';
                  }),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('region-$_country-$_region'),
                  initialValue: regions.contains(_region) ? _region : '',
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Region'),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('All regions'),
                    ),
                    for (final region in regions)
                      DropdownMenuItem(value: region, child: Text(region)),
                  ],
                  onChanged: (value) => setState(() => _region = value ?? ''),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${visible.length} surf spots${_showEvents && events?.isLoading != true && events?.hasError != true ? ' · $count ${count == 1 ? 'event' : 'events'}' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                tooltip: 'Refresh map',
                icon: const Icon(Icons.refresh),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  ref.invalidate(guestSpotsProvider);
                  if (_showEvents) ref.invalidate(guestEventsProvider);
                },
              ),
            ],
          ),
          if (_showEvents && events?.isLoading == true)
            const LinearProgressIndicator(),
          if (_showEvents && events?.hasError == true)
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Events could not load. The spot map is still available.',
                  ),
                ),
                TextButton(
                  onPressed: () => ref.invalidate(guestEventsProvider),
                  child: const Text('Retry events'),
                ),
              ],
            ),
          if (_showEvents &&
              events?.isLoading != true &&
              events?.hasError != true &&
              groups.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _country.isEmpty && _region.isEmpty && _search.text.isEmpty
                    ? 'No upcoming public events yet. Only public events with a date and mapped spot appear here.'
                    : 'No upcoming public events match these filters. Try All countries or another region.',
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
    final map = visible.isEmpty
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No mapped spots match. Try another place or clear your filters.',
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: GuestMapCanvas(
              key: ValueKey('$_country|$_region|${_search.text}'),
              spots: visible,
              eventGroups: groups,
              tileProviderFactory: ref.watch(guestTileProviderFactory),
              onSpot: (spot) => context.push('/spot/${spot.id}'),
              onEvents: (group) => showGuestEventPopup(context, group),
            ),
          );
    return LayoutBuilder(
      builder: (context, size) {
        final footer = Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tap a pin to explore. Sign in to save spots or join events.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              const TydesLegalLinks(
                includeAbout: true,
                includeSupport: true,
                dense: true,
                alignment: WrapAlignment.start,
              ),
            ],
          ),
        );
        final columns = size.maxWidth >= 1100
            ? 3
            : size.maxWidth >= 650
            ? 2
            : 1;
        final mapHeight = (size.maxHeight * .56)
            .clamp(320.0, size.maxWidth >= 900 ? 600.0 : 460.0)
            .toDouble();
        return CustomScrollView(
          key: const ValueKey('guest-explore-scroll'),
          controller: _scroll,
          slivers: [
            SliverToBoxAdapter(child: controls),
            SliverToBoxAdapter(
              child: SizedBox(height: mapHeight, child: map),
            ),
            SliverToBoxAdapter(child: footer),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        listTitle,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (!popularOnly)
                      Text(
                        '${browseSpots.length} spots',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
            if (browseSpots.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: Text(
                    'No spots match. Try another place or clear your filters.',
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    mainAxisExtent: 100,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => GuestSpotListCard(
                      spot: browseSpots[index],
                      onTap: () =>
                          context.push('/spot/${browseSpots[index].id}'),
                    ),
                    childCount: browseSpots.length,
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

class GuestSpotListCard extends StatelessWidget {
  const GuestSpotListCard({super.key, required this.spot, required this.onTap});
  final PublicMapSpotPreview spot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      key: ValueKey('guest-list-${spot.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFE1F4F2),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.waves, color: Color(0xFF078A91)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    spot.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${spot.area} · ${spot.region} · ${spot.country}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: Color(0xFF078A91)),
          ],
        ),
      ),
    ),
  );
}

class GuestMapCanvas extends StatefulWidget {
  const GuestMapCanvas({
    super.key,
    required this.spots,
    required this.eventGroups,
    required this.tileProviderFactory,
    required this.onSpot,
    required this.onEvents,
  });
  final List<PublicMapSpotPreview> spots;
  final List<GuestMapEventGroup> eventGroups;
  final TileProvider Function() tileProviderFactory;
  final ValueChanged<PublicMapSpotPreview> onSpot;
  final ValueChanged<GuestMapEventGroup> onEvents;
  @override
  State<GuestMapCanvas> createState() => _GuestMapCanvasState();
}

class _GuestMapCanvasState extends State<GuestMapCanvas> {
  final _controller = MapController();
  late final TileProvider _tiles = widget.tileProviderFactory();
  CameraFit get _fit => CameraFit.bounds(
    bounds: LatLngBounds.fromPoints(
      widget.spots.map((s) => LatLng(s.latitude, s.longitude)).toList(),
    ),
    padding: const EdgeInsets.all(48),
    maxZoom: 11,
  );
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(22),
    child: Stack(
      children: [
        SurfMapPinchGestures(
          controller: _controller,
          child: FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCameraFit: _fit,
              minZoom: 2,
              maxZoom: 14,
              interactionOptions: surfMapInteractionOptions,
            ),
            children: [
              TileLayer(
                urlTemplate: tiles.mapTileUrlTemplate,
                userAgentPackageName: tiles.mapTileUserAgent,
                tileProvider: _tiles,
              ),
              MarkerLayer(
                markers: [
                  for (final spot in widget.spots)
                    Marker(
                      width: 32,
                      height: 32,
                      point: LatLng(spot.latitude, spot.longitude),
                      child: IconButton(
                        key: ValueKey('guest-spot-${spot.id}'),
                        tooltip: spot.name,
                        padding: EdgeInsets.zero,
                        onPressed: () => widget.onSpot(spot),
                        icon: SurfMapSpotPin(difficulty: spot.difficulty),
                      ),
                    ),
                ],
              ),
              MarkerLayer(
                markers: [
                  for (final group in widget.eventGroups)
                    Marker(
                      width: 56,
                      height: 62,
                      point: LatLng(group.spot.latitude, group.spot.longitude),
                      child: GuestEventMarker(
                        group: group,
                        onTap: () => widget.onEvents(group),
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
      ],
    ),
  );
}

class GuestEventMarker extends StatelessWidget {
  const GuestEventMarker({super.key, required this.group, required this.onTap});
  final GuestMapEventGroup group;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final host = group.events.first;
    return SurfMapEventAvatar(
      displayName: host.hostName,
      avatarUrl: host.hostAvatarUrl,
      spotName: group.spot.name,
      eventCount: group.events.length,
      onTap: onTap,
      tapKey: ValueKey('guest-event-${group.spot.id}'),
    );
  }
}

String guestEventDateLabel(PublicEventPreview event) {
  String date(String? value) => value == null
      ? 'Date to be confirmed'
      : DateFormat('EEE, MMM d, y').format(DateTime.parse(value));
  return '${date(event.meetupDate)}${event.meetupEndDate != null && event.meetupEndDate != event.meetupDate ? ' – ${date(event.meetupEndDate)}' : ''}';
}

Future<void> showGuestEventPopup(
  BuildContext context,
  GuestMapEventGroup group,
) {
  Widget content(BuildContext popup) => GuestEventPopup(
    group: group,
    onView: (event) {
      Navigator.of(popup).pop();
      context.push('/post/${event.id}');
    },
    onJoin: (event) {
      Navigator.of(popup).pop();
      context.go(loginForPath('/post/${event.id}'));
    },
  );
  if (MediaQuery.sizeOf(context).width >= 760) {
    return showDialog<void>(
      context: context,
      builder: (popup) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 540,
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: content(popup),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .88,
    ),
    builder: content,
  );
}

class GuestEventPopup extends StatelessWidget {
  const GuestEventPopup({
    super.key,
    required this.group,
    required this.onView,
    required this.onJoin,
  });
  final GuestMapEventGroup group;
  final ValueChanged<PublicEventPreview> onView, onJoin;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Events at ${group.spot.name}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Text('${group.spot.area}, ${group.spot.region}, ${group.spot.country}'),
        const SizedBox(height: 12),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final event in group.events)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              TydesProfileAvatar(
                                displayName: event.hostName,
                                imageUrl: event.hostAvatarUrl,
                                size: 42,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      event.hostName,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    if (event.hostHandle?.isNotEmpty == true)
                                      Text('@${event.hostHandle}'),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Text(
                            event.body.isEmpty ? 'Surf meetup' : event.body,
                            maxLines: 6,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 10),
                          Text(guestEventDateLabel(event)),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: () => onView(event),
                                child: const Text('View event'),
                              ),
                              FilledButton.icon(
                                onPressed: () => onJoin(event),
                                icon: const Icon(Icons.login),
                                label: const Text('Sign in to join'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
