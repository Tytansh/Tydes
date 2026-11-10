import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';
import '../social/direct_messages_page.dart';
import '../social/event_chat_page.dart';
import '../social/social_feed.dart';
import '../social/social_profile.dart';
import '../trips/trips_page.dart';
import 'surf_map_markers.dart';

final mapEventPostsProvider = FutureProvider.autoDispose<List<SocialPostModel>>(
  (ref) {
    ref.watch(socialRefreshKeyProvider);
    final link = ref.keepAlive();
    final timer = Timer(const Duration(minutes: 2), link.close);
    ref.onDispose(timer.cancel);
    return ref.watch(surfRepositoryProvider).fetchMapEvents();
  },
);

final mapEventEngagementProvider =
    FutureProvider.autoDispose<SocialEngagementModel>((ref) {
      ref.watch(socialRefreshKeyProvider);
      return ref.watch(surfRepositoryProvider).fetchSocialEngagement();
    });

final mapEventAttendeesProvider = FutureProvider.autoDispose
    .family<List<EventAttendeeModel>, String>((ref, postId) {
      return ref.watch(surfRepositoryProvider).fetchEventAttendees(postId);
    });

class MapEvent {
  const MapEvent({
    required this.post,
    required this.spot,
    required this.start,
    required this.end,
  });

  final SocialPostModel post;
  final SpotModel spot;
  final DateTime start;
  final DateTime end;
}

class MapEventGroup {
  const MapEventGroup({required this.spot, required this.events});

  final SpotModel spot;
  final List<MapEvent> events;

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    return q.isEmpty ||
        [
          spot.name,
          spot.area,
          spot.region,
          spot.country,
          for (final event in events) ...[
            event.post.body,
            event.post.authorName,
            event.post.authorHandle ?? '',
          ],
        ].any((value) => value.toLowerCase().contains(q));
  }
}

List<MapEventGroup> buildMapEventGroups({
  required List<SocialPostModel> posts,
  required List<SpotModel> spots,
  required DateTime now,
  String? viewerId,
  Set<String> followedUserIds = const {},
  Set<String> blockedUserIds = const {},
}) {
  final today = DateUtils.dateOnly(now);
  final byId = {for (final spot in spots) spot.id: spot};
  final groups = <String, List<MapEvent>>{};
  for (final post in posts) {
    if (!{'surf_plan', 'looking_for_buddy'}.contains(post.postType) ||
        blockedUserIds.contains(post.userId)) {
      continue;
    }
    if (post.visibility != 'public' &&
        post.userId != viewerId &&
        !followedUserIds.contains(post.userId)) {
      continue;
    }
    final spot = byId[post.spotId];
    final start = DateTime.tryParse(post.meetupDate ?? '');
    final end = DateTime.tryParse(post.meetupEndDate ?? '') ?? start;
    if (spot == null ||
        start == null ||
        end == null ||
        end.isBefore(start) ||
        DateUtils.dateOnly(end).isBefore(today) ||
        !spot.latitude.isFinite ||
        !spot.longitude.isFinite ||
        spot.latitude.abs() > 90 ||
        spot.longitude.abs() > 180) {
      continue;
    }
    groups
        .putIfAbsent(spot.id, () => [])
        .add(MapEvent(post: post, spot: spot, start: start, end: end));
  }
  final result = <MapEventGroup>[];
  for (final entry in groups.entries) {
    entry.value.sort((a, b) => a.start.compareTo(b.start));
    result.add(MapEventGroup(spot: byId[entry.key]!, events: entry.value));
  }
  result.sort((a, b) => a.events.first.start.compareTo(b.events.first.start));
  return result;
}

String mapEventDateLabel(MapEvent event) {
  String label(DateTime date) =>
      '${date.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][date.month - 1]}';
  final start = label(event.start);
  return DateUtils.isSameDay(event.start, event.end)
      ? start
      : '$start – ${label(event.end)}';
}

Future<void> showMapEventPopup(BuildContext context, MapEventGroup group) {
  if (MediaQuery.sizeOf(context).width >= 760) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: MapEventPopup(group: group),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .88,
    ),
    builder: (_) => MapEventPopup(group: group),
  );
}

class MapEventMarker extends StatelessWidget {
  const MapEventMarker({
    super.key,
    required this.group,
    required this.onTap,
    this.viewerId,
  });

  final MapEventGroup group;
  final VoidCallback onTap;
  final String? viewerId;

  @override
  Widget build(BuildContext context) {
    final host = group.events
        .firstWhere(
          (event) => event.post.userId == viewerId,
          orElse: () => group.events.first,
        )
        .post;
    return SurfMapEventAvatar(
      displayName: host.authorName,
      avatarUrl: host.authorAvatarUrl,
      spotName: group.spot.name,
      eventCount: group.events.length,
      onTap: onTap,
      tapKey: ValueKey('map-event-marker-${group.spot.id}'),
    );
  }
}

class MapEventPopup extends ConsumerStatefulWidget {
  const MapEventPopup({super.key, required this.group});
  final MapEventGroup group;

  @override
  ConsumerState<MapEventPopup> createState() => _MapEventPopupState();
}

class _MapEventPopupState extends ConsumerState<MapEventPopup> {
  int _index = 0;
  bool _busy = false;

  void _navigate(String path, {Object? extra}) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.push(path, extra: extra);
  }

  Future<void> _join(MapEvent event, bool joined) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final engagement = await ref
          .read(surfRepositoryProvider)
          .setEventRsvp(postId: event.post.id, joined: !joined);
      ref.read(surfInviteRsvpProvider.notifier).state = engagement.rsvpPostIds;
      ref.invalidate(mapEventEngagementProvider);
      ref.invalidate(mapEventAttendeesProvider(event.post.id));
      ref.invalidate(mapEventPostsProvider);
      ref.invalidate(travelEventsProvider);
      ref.invalidate(travelEngagementProvider);
      ref.invalidate(joinedEventChatsProvider);
      if (mounted) setState(() => _busy = false);
      if (!joined && mounted) {
        await showEventChatJoinPrompt(
          context,
          postId: event.post.id,
          eventTitle: event.post.body,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update this event. Try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.group.events[_index];
    final post = event.post;
    final viewer = ref.watch(meProvider).valueOrNull;
    final engagement = ref.watch(mapEventEngagementProvider);
    final host = viewer?.id == post.userId;
    final localRsvps = ref.watch(surfInviteRsvpProvider);
    final joinedIds = engagement.valueOrNull?.rsvpPostIds ?? localRsvps;
    final joined = host || joinedIds.contains(post.id);
    final attendees = ref.watch(mapEventAttendeesProvider(post.id));
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.event_rounded, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Events at ${event.spot.name}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Close event',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (widget.group.events.length > 1) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < widget.group.events.length; i++)
                    ChoiceChip(
                      label: Text(
                        '${mapEventDateLabel(widget.group.events[i])} · ${widget.group.events[i].post.authorName}',
                      ),
                      selected: i == _index,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() => _index = i),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: TydesProfileAvatar(
                displayName: post.authorName,
                imageUrl: post.authorAvatarUrl,
                size: 48,
              ),
              title: Text(
                post.authorName,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                post.authorHandle?.isNotEmpty == true
                    ? '@${post.authorHandle} · Event host'
                    : 'Event host',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _navigate(
                '/profile/${post.userId}',
                extra: PublicProfilePreview(
                  userId: post.userId,
                  displayName: post.authorName,
                  handle: post.authorHandle,
                  avatarUrl: post.authorAvatarUrl,
                  premium: post.authorPremium,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              post.body.isEmpty
                  ? 'Surf meetup at ${event.spot.name}'
                  : post.body,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  avatar: const Icon(Icons.calendar_today_outlined, size: 16),
                  label: Text(mapEventDateLabel(event)),
                ),
                Chip(
                  avatar: const Icon(Icons.place_outlined, size: 16),
                  label: Text('${event.spot.area}, ${event.spot.country}'),
                ),
                if (post.visibility == 'followers')
                  const Chip(label: Text('Followers event')),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy || host || !engagement.hasValue
                    ? null
                    : () => _join(event, joined),
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
                label: Text(
                  host
                      ? 'You’re hosting'
                      : joined
                      ? 'Going · tap to leave'
                      : 'Join now',
                ),
              ),
            ),
            if (engagement.hasError)
              TextButton.icon(
                onPressed: () => ref.invalidate(mapEventEngagementProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry event status'),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                TextButton.icon(
                  onPressed: () => _navigate('/post/${post.id}'),
                  icon: const Icon(Icons.article_outlined),
                  label: const Text('See post'),
                ),
                if (joined)
                  TextButton.icon(
                    onPressed: () => _navigate('/event/${post.id}/chat'),
                    icon: const Icon(Icons.forum_outlined),
                    label: const Text('Group chat'),
                  ),
              ],
            ),
            const Divider(height: 28),
            Text(
              'Who’s going',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            attendees.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
              error: (_, _) => TextButton.icon(
                onPressed: () =>
                    ref.invalidate(mapEventAttendeesProvider(post.id)),
                icon: const Icon(Icons.refresh),
                label: const Text('Reload attendees'),
              ),
              data: (people) => Column(
                children: [
                  if (people.isEmpty)
                    const Text('Be the first to join this host.'),
                  for (final person in people)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: TydesProfileAvatar(
                        displayName: person.displayName,
                        imageUrl: person.avatarUrl,
                        size: 34,
                      ),
                      title: Text(person.displayName),
                      subtitle: Text(
                        person.organizer
                            ? 'Host'
                            : person.handle?.isNotEmpty == true
                            ? '@${person.handle}'
                            : 'Going',
                      ),
                      onTap: () => _navigate('/profile/${person.userId}'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
