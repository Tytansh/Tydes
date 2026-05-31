import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/surf_repository.dart';

final followedUserIdsProvider = StateProvider<Set<String>>((ref) => {});
final hiddenFollowingUserIdsProvider = StateProvider<Set<String>>((ref) => {});
final hiddenFollowerUserIdsProvider = StateProvider<Set<String>>((ref) => {});
final socialRelationshipHydrationProvider = FutureProvider<void>((ref) async {
  final saved = await ref
      .watch(demoPersistenceProvider)
      .loadSocialRelationships();
  ref.read(followedUserIdsProvider.notifier).state = saved.followedUserIds;
  ref.read(hiddenFollowingUserIdsProvider.notifier).state =
      saved.hiddenFollowingUserIds;
  ref.read(hiddenFollowerUserIdsProvider.notifier).state =
      saved.hiddenFollowerUserIds;
});

const tydesAvatarBackground = Color(0xFFE0F7F4);
const tydesAvatarForeground = Color(0xFF087E8B);

String tydesProfileInitial(String? name, {String fallback = '?'}) {
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty) return fallback;
  return trimmed.characters.first.toUpperCase();
}

class PublicProfilePreview {
  const PublicProfilePreview({
    required this.userId,
    required this.displayName,
    this.handle,
    this.avatarUrl,
    this.premium = false,
    this.subtitle,
    this.location,
    this.surfSkill = 'beginner',
  });

  final String userId;
  final String displayName;
  final String? handle;
  final String? avatarUrl;
  final bool premium;
  final String? subtitle;
  final String? location;
  final String surfSkill;
}

class ProfilePerson {
  const ProfilePerson({
    required this.profile,
    required this.subtitle,
    this.canFollow = true,
    this.forceFollowing = false,
    this.forceFollowerActions = false,
  });

  final PublicProfilePreview profile;
  final String subtitle;
  final bool canFollow;
  final bool forceFollowing;
  final bool forceFollowerActions;
}

class FollowButton extends ConsumerWidget {
  const FollowButton({
    super.key,
    required this.userId,
    this.expanded = false,
    this.compact = false,
  });

  final String userId;
  final bool expanded;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final following = _isFollowingUser(ref, userId);
    final button = compact
        ? (following
              ? OutlinedButton(
                  onPressed: () => _unfollowUser(ref, userId),
                  child: const Text('Following'),
                )
              : FilledButton(
                  onPressed: () => _followUser(ref, userId),
                  child: const Text('Follow'),
                ))
        : following
        ? OutlinedButton.icon(
            onPressed: () => _unfollowUser(ref, userId),
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('Following'),
          )
        : FilledButton.icon(
            onPressed: () => _followUser(ref, userId),
            icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
            label: const Text('Follow'),
          );

    if (expanded) return SizedBox(width: double.infinity, child: button);
    return button;
  }
}

class FollowingActions extends ConsumerWidget {
  const FollowingActions({super.key, required this.profile});

  final PublicProfilePreview profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.outlined(
          style: IconButton.styleFrom(
            foregroundColor: scheme.primary,
            side: BorderSide(color: scheme.outline),
          ),
          onPressed: () {
            Navigator.of(context).pop();
            _openDirectChat(context, profile);
          },
          icon: const Icon(Icons.mail_outline_rounded),
          tooltip: 'Message',
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () {
            final userId = profile.userId;
            final next = {...ref.read(followedUserIdsProvider)}..remove(userId);
            ref.read(followedUserIdsProvider.notifier).state = next;
            ref.read(hiddenFollowingUserIdsProvider.notifier).state = {
              ...ref.read(hiddenFollowingUserIdsProvider),
              userId,
            };
            _persistSocialRelationships(ref);
          },
          child: const Text('Unfollow'),
        ),
      ],
    );
  }
}

class FollowerActions extends ConsumerWidget {
  const FollowerActions({super.key, required this.profile});

  final PublicProfilePreview profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.outlined(
          style: IconButton.styleFrom(
            foregroundColor: scheme.primary,
            side: BorderSide(color: scheme.outline),
          ),
          onPressed: () {
            final userId = profile.userId;
            ref.read(hiddenFollowerUserIdsProvider.notifier).state = {
              ...ref.read(hiddenFollowerUserIdsProvider),
              userId,
            };
            _persistSocialRelationships(ref);
          },
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Remove follower',
        ),
        const SizedBox(width: 8),
        IconButton.outlined(
          style: IconButton.styleFrom(
            foregroundColor: scheme.primary,
            side: BorderSide(color: scheme.outline),
          ),
          onPressed: () {
            Navigator.of(context).pop();
            _openDirectChat(context, profile);
          },
          icon: const Icon(Icons.mail_outline_rounded),
          tooltip: 'Message',
        ),
        const SizedBox(width: 8),
        FollowButton(userId: profile.userId, compact: true),
      ],
    );
  }
}

const _defaultFollowedUserIds = {
  'friend_lina',
  'friend_ari',
  'friend_jo',
  'friend_maya',
  'friend_kai',
  'friend_noa',
  'friend_sam',
};

bool _isFollowingUser(WidgetRef ref, String userId) {
  final hiddenFollowingUserIds = ref.watch(hiddenFollowingUserIdsProvider);
  if (hiddenFollowingUserIds.contains(userId)) return false;
  return ref.watch(followedUserIdsProvider).contains(userId) ||
      _defaultFollowedUserIds.contains(userId);
}

void _followUser(WidgetRef ref, String userId) {
  ref.read(hiddenFollowingUserIdsProvider.notifier).state = {
    ...ref.read(hiddenFollowingUserIdsProvider),
  }..remove(userId);
  ref.read(followedUserIdsProvider.notifier).state = {
    ...ref.read(followedUserIdsProvider),
    userId,
  };
  _persistSocialRelationships(ref);
}

void _unfollowUser(WidgetRef ref, String userId) {
  final next = {...ref.read(followedUserIdsProvider)}..remove(userId);
  ref.read(followedUserIdsProvider.notifier).state = next;
  if (_defaultFollowedUserIds.contains(userId)) {
    ref.read(hiddenFollowingUserIdsProvider.notifier).state = {
      ...ref.read(hiddenFollowingUserIdsProvider),
      userId,
    };
  }
  _persistSocialRelationships(ref);
}

void _persistSocialRelationships(WidgetRef ref) {
  unawaited(
    ref
        .read(demoPersistenceProvider)
        .saveSocialRelationships(
          followedUserIds: ref.read(followedUserIdsProvider),
          hiddenFollowingUserIds: ref.read(hiddenFollowingUserIdsProvider),
          hiddenFollowerUserIds: ref.read(hiddenFollowerUserIdsProvider),
        ),
  );
}

void _openDirectChat(BuildContext context, PublicProfilePreview profile) {
  final threadId = _messageThreadIdForProfile(profile);
  context.push('/messages?thread=$threadId', extra: profile);
}

String _messageThreadIdForProfile(PublicProfilePreview profile) {
  final handle = profile.handle?.trim().replaceFirst('@', '');
  if (handle != null && handle.isNotEmpty) return handle.toLowerCase();
  var id = profile.userId.toLowerCase();
  if (id.startsWith('friend_')) id = id.substring('friend_'.length);
  if (id.startsWith('suggested_')) id = id.substring('suggested_'.length);
  if (id.startsWith('random_')) id = id.substring('random_'.length);
  return id.replaceAll(RegExp(r'[^a-z0-9_]+'), '');
}

Future<void> showProfilePeopleSheet({
  required BuildContext context,
  required String title,
  required List<ProfilePerson> people,
  required ValueChanged<PublicProfilePreview> onProfileTap,
  String emptyText = 'No people here yet.',
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => _ProfilePeopleSheet(
      title: title,
      people: people,
      onProfileTap: onProfileTap,
      emptyText: emptyText,
    ),
  );
}

class _ProfilePeopleSheet extends ConsumerWidget {
  const _ProfilePeopleSheet({
    required this.title,
    required this.people,
    required this.onProfileTap,
    required this.emptyText,
  });

  final String title;
  final List<ProfilePerson> people;
  final ValueChanged<PublicProfilePreview> onProfileTap;
  final String emptyText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hiddenFollowingUserIds = ref.watch(hiddenFollowingUserIdsProvider);
    final hiddenFollowerUserIds = ref.watch(hiddenFollowerUserIdsProvider);
    final visiblePeople = people
        .where(
          (person) =>
              (!person.forceFollowing ||
                  !hiddenFollowingUserIds.contains(person.profile.userId)) &&
              (!person.forceFollowerActions ||
                  !hiddenFollowerUserIds.contains(person.profile.userId)),
        )
        .toList();

    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(title, style: theme.textTheme.headlineMedium),
            const SizedBox(height: 14),
            if (visiblePeople.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Text(emptyText),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: visiblePeople.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final person = visiblePeople[index];
                    return _ProfilePersonTile(
                      person: person,
                      onTap: () {
                        Navigator.of(context).pop();
                        onProfileTap(person.profile);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProfilePersonTile extends StatelessWidget {
  const _ProfilePersonTile({required this.person, required this.onTap});

  final ProfilePerson person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final profile = person.profile;

    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: tydesAvatarBackground,
              backgroundImage: profile.avatarUrl == null
                  ? null
                  : NetworkImage(profile.avatarUrl!),
              child: profile.avatarUrl == null
                  ? Text(
                      tydesProfileInitial(profile.displayName),
                      style: const TextStyle(
                        color: tydesAvatarForeground,
                        fontWeight: FontWeight.w800,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          profile.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (profile.premium) ...[
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.verified_rounded,
                          size: 16,
                          color: Color(0xFF2AA7A1),
                        ),
                      ],
                    ],
                  ),
                  Text(person.subtitle, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (person.forceFollowerActions)
              FollowerActions(profile: profile)
            else if (person.forceFollowing)
              FollowingActions(profile: profile)
            else if (person.canFollow)
              FollowButton(userId: profile.userId, compact: true)
            else
              const Chip(label: Text('You')),
          ],
        ),
      ),
    );
  }
}
