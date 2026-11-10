import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';
import '../social/direct_messages_page.dart';
import '../social/event_chat_page.dart';

final travelSpotsProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchSpots(),
);

final nextSwellProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchNextSwell(),
);

final travelEventsProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchSocialPosts(),
);

final travelEngagementProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchSocialEngagement(),
);

enum _EventScope { area, region, country }

class TripsPage extends ConsumerStatefulWidget {
  const TripsPage({super.key});

  @override
  ConsumerState<TripsPage> createState() => _TripsPageState();
}

class _TripsPageState extends ConsumerState<TripsPage> {
  String? _selectedCountryId;
  String? _selectedRegionId;
  String? _selectedAreaId;
  _EventScope _eventScope = _EventScope.area;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Travel'),
        backgroundColor: const Color(0xFFF8F7F2),
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: ref
          .watch(travelSpotsProvider)
          .when(
            data: (spots) => _TravelLoadedBody(
              spots: spots,
              nextSwell: ref.watch(nextSwellProvider),
              events: ref.watch(travelEventsProvider),
              selectedCountryId: _selectedCountryId,
              selectedRegionId: _selectedRegionId,
              selectedAreaId: _selectedAreaId,
              eventScope: _eventScope,
              onLocationChanged: (selection) {
                setState(() {
                  _selectedCountryId = selection.countryId;
                  _selectedRegionId = selection.regionId;
                  _selectedAreaId = selection.areaId;
                  _eventScope = selection.scope;
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
    required this.nextSwell,
    required this.events,
    required this.selectedCountryId,
    required this.selectedRegionId,
    required this.selectedAreaId,
    required this.eventScope,
    required this.onLocationChanged,
  });

  final List<SpotModel> spots;
  final AsyncValue<NextSwellModel> nextSwell;
  final AsyncValue<List<SocialPostModel>> events;
  final String? selectedCountryId;
  final String? selectedRegionId;
  final String? selectedAreaId;
  final _EventScope eventScope;
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
    final totalBreaks = countries.fold<int>(
      0,
      (total, country) => total + country.breakCount,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 32),
      children: [
        _TravelHero(countryCount: countries.length, breakCount: totalBreaks),
        const SizedBox(height: 16),
        const _TravelServicesComingSoonCard(),
        const SizedBox(height: 16),
        _NextSwellCard(recommendation: nextSwell),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: Text(
                'Find event',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            _StatusPill(
              label: '${selectedCountry?.breakCount ?? totalBreaks} breaks',
            ),
          ],
        ),
        const SizedBox(height: 10),
        _TravelLocationButton(
          countries: countries,
          country: selectedCountry,
          region: selectedRegion,
          area: selectedArea,
          onChanged: onLocationChanged,
        ),
        if (selectedCountry != null && selectedArea != null) ...[
          const SizedBox(height: 10),
          _TravelAreaOverview(
            country: selectedCountry,
            region: selectedRegion!,
            area: selectedArea,
          ),
        ],
        if (_canShowEvents(
          scope: eventScope,
          country: selectedCountry,
          region: selectedRegion,
          area: selectedArea,
        )) ...[
          const SizedBox(height: 20),
          _TravelEventsSection(
            posts: events,
            spots: spots,
            country: selectedCountry!,
            region: selectedRegion,
            area: selectedArea,
            scope: eventScope,
          ),
        ],
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

class _TravelHero extends StatelessWidget {
  const _TravelHero({required this.countryCount, required this.breakCount});

  final int countryCount;
  final int breakCount;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: Container(
        padding: const EdgeInsets.all(22),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF073E59), Color(0xFF009AA4), Color(0xFF70CAB2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            const Positioned(right: -24, top: -38, child: _HeroSun()),
            const Positioned(
              right: -14,
              bottom: -20,
              child: Icon(
                Icons.waves_rounded,
                color: Color(0x33FFFFFF),
                size: 150,
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x2BFFFFFF),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0x35FFFFFF)),
                  ),
                  child: const Text(
                    'TYDES TRIP PLANNER',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'Go where the swell is.',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontSize: 29,
                    fontWeight: FontWeight.w900,
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 8),
                const SizedBox(
                  width: 300,
                  child: Text(
                    'Explore mapped surf regions now. Accommodations, rentals, local shops, and smarter trip tools are on the way.',
                    style: TextStyle(
                      color: Color(0xE6FFFFFF),
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _HeroStat(label: '$countryCount countries'),
                    const SizedBox(width: 8),
                    _HeroStat(label: '$breakCount surf breaks'),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroSun extends StatelessWidget {
  const _HeroSun();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 126,
      height: 126,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [Color(0x99F5D38B), Color(0x12F5D38B)],
        ),
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x26FFFFFF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: const Color(0xFF6D716D)),
        ),
      ],
    );
  }
}

class _NextSwellCard extends StatelessWidget {
  const _NextSwellCard({required this.recommendation});

  final AsyncValue<NextSwellModel> recommendation;

  @override
  Widget build(BuildContext context) {
    return recommendation.when(
      data: (result) => result.available
          ? _buildRecommendation(context, result)
          : _buildUnavailable(context, result.summary),
      loading: () => _buildLoading(context),
      error: (_, _) => _buildUnavailable(
        context,
        'The live swell scan is unavailable right now.',
      ),
    );
  }

  Widget _buildRecommendation(BuildContext context, NextSwellModel result) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF073E59), Color(0xFF087E7A), Color(0xFF35B6A5)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26073E59),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.radar_rounded, color: Colors.white, size: 24),
              const SizedBox(width: 9),
              const Text(
                'NEXT SWELL',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0x2BFFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0x45FFFFFF)),
                ),
                child: Text(
                  result.quality.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    letterSpacing: .7,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            result.destination ?? 'Destination unavailable',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            'Best break • ${result.spotName ?? 'Unavailable'}',
            style: const TextStyle(
              color: Color(0xE6FFFFFF),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 15),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _NextSwellMetric(
                icon: Icons.calendar_today_outlined,
                label: _formatForecastDay(result.bestDay),
              ),
              _NextSwellMetric(
                icon: Icons.waves_rounded,
                label: '${_formatMetric(result.swellHeightM)}m swell',
              ),
              _NextSwellMetric(
                icon: Icons.timeline_rounded,
                label: '${result.periodS ?? '--'}s period',
              ),
              _NextSwellMetric(
                icon: Icons.air_rounded,
                label: '${_formatMetric(result.windKts)}kt wind',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            result.summary ?? '',
            style: const TextStyle(
              color: Color(0xE6FFFFFF),
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          Container(height: 1, color: const Color(0x35FFFFFF)),
          const SizedBox(height: 11),
          Text(
            '${_sourceLabel(result.source)} • updated ${_formatUpdatedAt(result.updatedAt)}\n${result.note}',
            style: const TextStyle(
              color: Color(0xCFFFFFFF),
              fontSize: 10.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading(BuildContext context) {
    return Container(
      height: 190,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF0A514F),
        borderRadius: BorderRadius.circular(26),
      ),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 14),
            Text(
              'Scanning the next five days…',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnavailable(BuildContext context, String? summary) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFE9F5F2),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFCCE7E1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.radar_rounded, color: Color(0xFF087E7A), size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No standout trip yet',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  summary ??
                      'No travel-worthy swell stands out in the next five days.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Watching Taiwan, Indonesia, Siargao, Sri Lanka, and Australia.',
                  style: TextStyle(
                    color: Color(0xFF087E7A),
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NextSwellMetric extends StatelessWidget {
  const _NextSwellMetric({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0x26FFFFFF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x35FFFFFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 15),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatMetric(double? value) {
  if (value == null) return '--';
  final fixed = value.toStringAsFixed(1);
  return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
}

String _formatForecastDay(String? value) {
  final day = value == null ? null : DateTime.tryParse(value);
  if (day == null) return 'Date pending';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[day.month - 1]} ${day.day}';
}

String _formatUpdatedAt(String value) {
  final parsed = DateTime.tryParse(value)?.toLocal();
  if (parsed == null) return 'recently';
  final minute = parsed.minute.toString().padLeft(2, '0');
  final hour = parsed.hour % 12 == 0 ? 12 : parsed.hour % 12;
  final suffix = parsed.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $suffix';
}

String _sourceLabel(String source) {
  if (source.toLowerCase() == 'open-meteo') return 'Open-Meteo';
  return source;
}

class _TravelServicesComingSoonCard extends StatelessWidget {
  const _TravelServicesComingSoonCard();

  static const _services = [
    (icon: Icons.bed_outlined, label: 'Hostels & stays'),
    (icon: Icons.two_wheeler_outlined, label: 'Scooter rentals'),
    (icon: Icons.surfing_outlined, label: 'Board shops'),
    (icon: Icons.route_outlined, label: 'Trip planner'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFE9F5F2),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFCCE7E1)),
      ),
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
                child: const Icon(
                  Icons.travel_explore_outlined,
                  color: Color(0xFF087E7A),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Everything you need around the break',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const _StatusPill(label: 'Coming soon'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Verified hostels and accommodations, scooter rentals, board shops, and personal trip planning are coming soon.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF394340),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _services
                .map(
                  (service) => _TravelServicePill(
                    icon: service.icon,
                    label: service.label,
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _TravelServicePill extends StatelessWidget {
  const _TravelServicePill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFBEDFD9)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17, color: const Color(0xFF087E7A)),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF164B49),
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _TravelAreaOverview extends StatelessWidget {
  const _TravelAreaOverview({
    required this.country,
    required this.region,
    required this.area,
  });

  final _TravelCountryView country;
  final _TravelRegionView region;
  final _TravelAreaView area;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF1EEE5),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${region.name.toUpperCase()} • ${country.name.toUpperCase()}',
            style: const TextStyle(
              color: Color(0xFF087E7A),
              fontSize: 10,
              letterSpacing: .7,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            area.summary,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF394340),
              height: 1.35,
            ),
          ),
          if (area.nearSpots.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: area.nearSpots
                  .take(4)
                  .map(
                    (spot) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        spot,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _TravelEventsSection extends ConsumerWidget {
  const _TravelEventsSection({
    required this.posts,
    required this.spots,
    required this.country,
    required this.region,
    required this.area,
    required this.scope,
  });

  final AsyncValue<List<SocialPostModel>> posts;
  final List<SpotModel> spots;
  final _TravelCountryView country;
  final _TravelRegionView? region;
  final _TravelAreaView? area;
  final _EventScope scope;

  String get _scopeName => switch (scope) {
    _EventScope.area => area?.name ?? country.name,
    _EventScope.region => region?.name ?? country.name,
    _EventScope.country => country.name,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final joinedPostIds =
        ref.watch(travelEngagementProvider).valueOrNull?.rsvpPostIds ??
        const <String>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeading(
          title: 'Events in $_scopeName',
          subtitle: 'Upcoming surf meetups, from local to country-wide',
        ),
        const SizedBox(height: 10),
        posts.when(
          data: (items) {
            final events = _eventsForLocation(
              items,
              spots,
              country: country.name,
              region: region?.name,
              area: area?.name,
              scope: scope,
            );
            if (events.isEmpty) {
              return _EmptyTravelEventsCard(areaName: _scopeName);
            }
            final visibleEvents = events.take(8).toList();
            return Column(
              children: [
                for (final event in visibleEvents) ...[
                  _TravelEventCard(
                    event: event,
                    joined: joinedPostIds.contains(event.post.id),
                  ),
                  if (event != visibleEvents.last) const SizedBox(height: 10),
                ],
              ],
            );
          },
          loading: () => const _TravelEventsLoadingCard(),
          error: (_, _) => const _TravelEventsUnavailableCard(),
        ),
      ],
    );
  }
}

class _TravelEventCard extends ConsumerStatefulWidget {
  const _TravelEventCard({required this.event, required this.joined});

  final _TravelEventView event;
  final bool joined;

  @override
  ConsumerState<_TravelEventCard> createState() => _TravelEventCardState();
}

class _TravelEventCardState extends ConsumerState<_TravelEventCard> {
  bool _busy = false;

  Future<void> _toggleJoin() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(surfRepositoryProvider)
          .setEventRsvp(postId: widget.event.post.id, joined: !widget.joined);
      ref.invalidate(travelEngagementProvider);
      ref.invalidate(travelEventsProvider);
      ref.invalidate(joinedEventChatsProvider);
      if (!widget.joined && mounted) {
        await showEventChatJoinPrompt(
          context,
          postId: widget.event.post.id,
          eventTitle: widget.event.post.body,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update this event right now.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showAttendees() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _EventAttendeesSheet(postId: widget.event.post.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final body = event.post.body.trim();
    final isHost = ref.watch(meProvider).valueOrNull?.id == event.post.userId;
    final joined = isHost || widget.joined;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF6F4),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFC7E5E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF087E7A),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Column(
                  children: [
                    Text(
                      _eventMonth(event.date),
                      style: const TextStyle(
                        color: Color(0xFFD8F3EE),
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      '${event.date.day}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        height: 1.05,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      body.isEmpty ? 'Surf meetup at ${event.spot.name}' : body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${event.spot.name} • ${event.post.authorName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF52625F),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy || isHost ? null : _toggleJoin,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        joined
                            ? Icons.check_circle_outline
                            : Icons.add_circle_outline,
                      ),
                label: Text(joined ? 'Going' : 'Join now'),
              ),
              OutlinedButton.icon(
                onPressed: _showAttendees,
                icon: const Icon(Icons.groups_2_outlined),
                label: Text(
                  event.post.rsvpCount > 0
                      ? 'Who’s going (${event.post.rsvpCount + 1})'
                      : 'Who’s going',
                ),
              ),
              TextButton.icon(
                onPressed: () => context.push('/post/${event.post.id}'),
                icon: const Icon(Icons.article_outlined),
                label: const Text('See post'),
              ),
              if (joined)
                TextButton.icon(
                  onPressed: () => context.push('/event/${event.post.id}/chat'),
                  icon: const Icon(Icons.forum_outlined),
                  label: const Text('Group chat'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EventAttendeesSheet extends ConsumerWidget {
  const _EventAttendeesSheet({required this.postId});

  final String postId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
        child: FutureBuilder<List<EventAttendeeModel>>(
          future: ref.read(surfRepositoryProvider).fetchEventAttendees(postId),
          builder: (context, snapshot) {
            if (!snapshot.hasData && !snapshot.hasError) {
              return const SizedBox(
                height: 220,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return const SizedBox(
                height: 180,
                child: Center(
                  child: Text('Could not load attendees right now.'),
                ),
              );
            }
            final attendees = snapshot.data!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Who’s going',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                for (final attendee in attendees)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundImage: attendee.avatarUrl == null
                          ? null
                          : NetworkImage(attendee.avatarUrl!),
                      child: attendee.avatarUrl == null
                          ? Text(
                              attendee.displayName.trim().isEmpty
                                  ? '?'
                                  : attendee.displayName
                                        .trim()[0]
                                        .toUpperCase(),
                            )
                          : null,
                    ),
                    title: Text(attendee.displayName),
                    subtitle: Text(
                      attendee.organizer
                          ? 'Organizer'
                          : attendee.handle == null
                          ? 'Going'
                          : '@${attendee.handle}',
                    ),
                    trailing: attendee.organizer
                        ? const Icon(
                            Icons.star_rounded,
                            color: Color(0xFF087E7A),
                          )
                        : const Icon(
                            Icons.check_circle,
                            color: Color(0xFF2AA7A1),
                          ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _EmptyTravelEventsCard extends StatelessWidget {
  const _EmptyTravelEventsCard({required this.areaName});

  final String areaName;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF2EEE6),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.event_available_outlined, color: Color(0xFF087E7A)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No upcoming events in $areaName',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'When someone plans a surf here, it will show up automatically.',
                  style: TextStyle(color: Color(0xFF626A66), height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TravelEventsLoadingCard extends StatelessWidget {
  const _TravelEventsLoadingCard();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 92,
      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }
}

class _TravelEventsUnavailableCard extends StatelessWidget {
  const _TravelEventsUnavailableCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Text('Could not load events for this location right now.'),
      ),
    );
  }
}

class _TravelLocationButton extends StatelessWidget {
  const _TravelLocationButton({
    required this.countries,
    required this.country,
    required this.region,
    required this.area,
    required this.onChanged,
  });

  final List<_TravelCountryView> countries;
  final _TravelCountryView? country;
  final _TravelRegionView? region;
  final _TravelAreaView? area;
  final ValueChanged<_TravelLocationSelection> onChanged;

  Future<void> _openSelector(BuildContext context) async {
    final selection = await showModalBottomSheet<_TravelLocationSelection>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _TravelLocationSheet(
        countries: countries,
        selectedCountryId: country?.id,
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
      key: const Key('travel-location-picker'),
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
                    area?.name ?? region?.name ?? country?.name ?? 'Find event',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(switch ((country, region, area)) {
                    (null, _, _) => 'Pick a country, coast, and surf area',
                    (final selectedCountry?, null, _) =>
                      'All events in ${selectedCountry.name}',
                    (final selectedCountry?, final selectedRegion?, null) =>
                      'All events in ${selectedRegion.name}, ${selectedCountry.name}',
                    (
                      final selectedCountry?,
                      final selectedRegion?,
                      final selectedArea?,
                    ) =>
                      '${selectedRegion.name}, ${selectedCountry.name} • ${selectedArea.breakCountLabel}',
                  }, style: Theme.of(context).textTheme.bodySmall),
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

class _TravelLocationSheet extends StatefulWidget {
  const _TravelLocationSheet({
    required this.countries,
    required this.selectedCountryId,
    required this.selectedRegionId,
    required this.selectedAreaId,
  });

  final List<_TravelCountryView> countries;
  final String? selectedCountryId;
  final String? selectedRegionId;
  final String? selectedAreaId;

  @override
  State<_TravelLocationSheet> createState() => _TravelLocationSheetState();
}

class _TravelLocationSheetState extends State<_TravelLocationSheet> {
  late String _countryId;

  @override
  void initState() {
    super.initState();
    _countryId =
        widget.selectedCountryId ??
        _firstWhereOrNull(
          widget.countries,
          (country) => country.name == 'Indonesia',
        )?.id ??
        widget.countries.first.id;
  }

  _TravelCountryView get _country =>
      _firstWhereOrNull(
        widget.countries,
        (country) => country.id == _countryId,
      ) ??
      widget.countries.first;

  @override
  Widget build(BuildContext context) {
    final country = _country;
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
                'Find event',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Pick a country, then choose the surf area you want to explore.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: country.id,
                decoration: const InputDecoration(
                  labelText: 'Country',
                  prefixIcon: Icon(Icons.public_rounded),
                ),
                icon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      key: const Key('travel-country-see-all'),
                      onPressed: () => Navigator.of(context).pop(
                        _TravelLocationSelection(
                          countryId: country.id,
                          regionId: null,
                          areaId: null,
                          scope: _EventScope.country,
                        ),
                      ),
                      child: const Text('See all'),
                    ),
                    const Icon(Icons.arrow_drop_down_rounded),
                  ],
                ),
                items: widget.countries
                    .map(
                      (item) => DropdownMenuItem(
                        value: item.id,
                        child: Text('${item.emoji}  ${item.name}'),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null || value == _countryId) return;
                  setState(() => _countryId = value);
                },
              ),
              const SizedBox(height: 14),
              ...country.regions.map(
                (region) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _TravelRegionTile(
                    country: country,
                    region: region,
                    selectedRegionId: country.id == widget.selectedCountryId
                        ? widget.selectedRegionId
                        : null,
                    selectedAreaId: country.id == widget.selectedCountryId
                        ? widget.selectedAreaId
                        : null,
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

class _TravelRegionTile extends StatefulWidget {
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
  State<_TravelRegionTile> createState() => _TravelRegionTileState();
}

class _TravelRegionTileState extends State<_TravelRegionTile> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded =
        widget.selectedRegionId != null &&
        widget.region.id == widget.selectedRegionId;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF2EEE6),
        borderRadius: BorderRadius.circular(22),
      ),
      child: ExpansionTile(
        initiallyExpanded: _expanded,
        onExpansionChanged: (expanded) {
          setState(() => _expanded = expanded);
        },
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
        ),
        title: Text(
          widget.region.name,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '${widget.region.areas.length} areas • ${widget.region.breakCountLabel}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              key: ValueKey('travel-region-see-all-${widget.region.name}'),
              onPressed: () => Navigator.of(context).pop(
                _TravelLocationSelection(
                  countryId: widget.country.id,
                  regionId: widget.region.id,
                  areaId: null,
                  scope: _EventScope.region,
                ),
              ),
              child: const Text('See all'),
            ),
            AnimatedRotation(
              turns: _expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
          ],
        ),
        children: widget.region.areas
            .map(
              (area) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _TravelAreaTile(
                  country: widget.country,
                  region: widget.region,
                  area: area,
                  selected:
                      widget.region.id == widget.selectedRegionId &&
                      area.id == widget.selectedAreaId,
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
        onTap: () => Navigator.of(context).pop(
          _TravelLocationSelection(
            countryId: country.id,
            regionId: region.id,
            areaId: area.id,
            scope: _EventScope.area,
          ),
        ),
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
  });

  final String id;
  final String name;
  final String summary;
  final List<String> nearSpots;
  final int breakCount;

  String get breakCountLabel {
    return breakCount == 1 ? '1 break nearby' : '$breakCount breaks nearby';
  }

  String get nearSpotsLabel {
    if (nearSpots.isEmpty) return 'local surf base';
    return nearSpots.take(3).join(', ');
  }
}

class _TravelLocationSelection {
  const _TravelLocationSelection({
    required this.countryId,
    required this.regionId,
    required this.areaId,
    required this.scope,
  });

  final String countryId;
  final String? regionId;
  final String? areaId;
  final _EventScope scope;
}

class _TravelEventView {
  const _TravelEventView({
    required this.post,
    required this.spot,
    required this.date,
  });

  final SocialPostModel post;
  final SpotModel spot;
  final DateTime date;
}

List<_TravelEventView> _eventsForLocation(
  List<SocialPostModel> posts,
  List<SpotModel> spots, {
  required String country,
  required String? region,
  required String? area,
  required _EventScope scope,
}) {
  final spotsById = {for (final spot in spots) spot.id: spot};
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final events = <_TravelEventView>[];

  for (final post in posts) {
    if (post.postType != 'surf_plan' || post.meetupDate == null) continue;
    final date = DateTime.tryParse(post.meetupDate!);
    final spot = post.spotId == null ? null : spotsById[post.spotId];
    if (date == null || date.isBefore(today) || spot == null) continue;
    final matchesLocation = switch (scope) {
      _EventScope.country => spot.country == country,
      _EventScope.region => spot.country == country && spot.region == region,
      _EventScope.area =>
        spot.country == country && spot.region == region && spot.area == area,
    };
    if (!matchesLocation) {
      continue;
    }
    events.add(_TravelEventView(post: post, spot: spot, date: date));
  }

  events.sort((a, b) {
    final dateCompare = a.date.compareTo(b.date);
    if (dateCompare != 0) return dateCompare;
    return a.post.createdAt.compareTo(b.post.createdAt);
  });
  return events;
}

bool _canShowEvents({
  required _EventScope scope,
  required _TravelCountryView? country,
  required _TravelRegionView? region,
  required _TravelAreaView? area,
}) {
  return switch (scope) {
    _EventScope.country => country != null,
    _EventScope.region => country != null && region != null,
    _EventScope.area => country != null && region != null && area != null,
  };
}

String _eventMonth(DateTime date) {
  const months = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ];
  return months[date.month - 1];
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
        final areas = _buildDynamicTravelAreas(country, entry.key, entry.value);
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
          'Explore ${entry.value.length} mapped surf ${entry.value.length == 1 ? 'break' : 'breaks'} around ${entry.key} in $region, $country.',
      nearSpots: nearSpots,
      breakCount: entry.value.length,
    );
  }).toList();

  areas.sort((a, b) {
    final countCompare = b.breakCount.compareTo(a.breakCount);
    if (countCompare != 0) return countCompare;
    return a.name.compareTo(b.name);
  });
  return areas;
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
    'Taiwan': 'TW',
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
    'Taiwan',
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
