import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as image_tools;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/router.dart';
import '../../core/billing/revenuecat_service.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';
import '../social/direct_messages_page.dart';
import '../social/social_feed.dart';
import '../social/social_profile.dart';
import '../spots/spot_detail_page.dart';
import '../spots/spots_page.dart';

final friendsProvider = FutureProvider((ref) {
  ref.watch(socialRefreshKeyProvider);
  return ref.watch(surfRepositoryProvider).fetchFriends();
});

final socialPostsProvider = FutureProvider((ref) {
  ref.watch(socialRefreshKeyProvider);
  return ref.watch(surfRepositoryProvider).fetchSocialPosts();
});

final unreadSocialNotificationsProvider = StateProvider<int>((ref) => 0);

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  Future<void> _refreshProfile(WidgetRef ref) async {
    ref.invalidate(meProvider);
    ref.invalidate(friendsProvider);
    ref.invalidate(socialPostsProvider);
    ref.invalidate(spotsProvider);
    await Future.wait([
      ref.read(meProvider.future),
      ref.read(friendsProvider.future),
      ref.read(socialPostsProvider.future),
      ref.read(spotsProvider.future),
      ref.refresh(socialEngagementHydrationProvider.future),
    ]);
  }

  Future<void> _openProfileSettings(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<UserProfile> me,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ProfileSettingsSheet(
        profile: me.valueOrNull,
        premium: me.valueOrNull?.premium ?? false,
        selectedLocale: ref.watch(localeProvider),
        onLocaleChanged: (locale) =>
            ref.read(localeProvider.notifier).state = locale,
        onEditProfile: me.valueOrNull == null
            ? null
            : () async {
                Navigator.of(context).pop();
                await showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (context) =>
                      _EditProfileSheet(profile: me.valueOrNull!),
                );
              },
        onManagePremium: () {
          Navigator.of(context).pop();
          context.push('/paywall');
        },
        onLogout: () async {
          await ref.read(surfRepositoryProvider).logout();
          await ref.read(revenueCatServiceProvider).logOut();
          ref.invalidate(meProvider);
          ref.invalidate(dashboardProvider);
          ref.invalidate(homeAdsProvider);
          ref.invalidate(spotsProvider);
          ref.invalidate(spotForecastsBySpotProvider);
          ref.invalidate(spotCardForecastProvider);
          ref.invalidate(spotTideProvider);
          ref.invalidate(spotDetailBundleProvider);
          if (!context.mounted) return;
          Navigator.of(context).pop();
          context.push('/login');
        },
        onDeleteAccount: () async {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Delete account?'),
              content: const Text(
                'This removes this test account from the backend so the email can sign up again.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB3261E),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (confirmed != true) return;
          await ref.read(surfRepositoryProvider).deleteAccount();
          await ref.read(revenueCatServiceProvider).logOut();
          ref.invalidate(meProvider);
          ref.invalidate(dashboardProvider);
          ref.invalidate(homeAdsProvider);
          ref.invalidate(spotsProvider);
          ref.invalidate(spotForecastsBySpotProvider);
          ref.invalidate(spotCardForecastProvider);
          ref.invalidate(spotTideProvider);
          ref.invalidate(spotDetailBundleProvider);
          if (!context.mounted) return;
          Navigator.of(context).pop();
          context.push('/login');
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final friends = ref.watch(friendsProvider);
    final posts = ref.watch(socialPostsProvider);
    final spots = ref.watch(spotsProvider);
    final followedUserIds = ref.watch(followedUserIdsProvider);
    final hiddenFollowingUserIds = ref.watch(hiddenFollowingUserIdsProvider);
    final hiddenFollowerUserIds = ref.watch(hiddenFollowerUserIdsProvider);
    final unreadMessageThreads = ref.watch(
      unreadDirectMessageThreadCountProvider,
    );
    final unreadNotifications = ref.watch(unreadSocialNotificationsProvider);
    final visibleRepostedPostIds = ref.watch(visibleRepostedPostIdsProvider);
    final visibleRepostActivityTimes = ref.watch(
      visibleRepostActivityTimesProvider,
    );
    ref.watch(socialEngagementHydrationProvider);
    final followingPeople = _profileFriendPeople(
      friends.valueOrNull ?? const [],
      followedUserIds,
      hiddenFollowingUserIds,
    );
    final followerPeople = _profileFollowerPeople(hiddenFollowerUserIds);
    final excludedSuggestionIds = {
      ...followingPeople.map((person) => person.profile.userId),
      ...followerPeople.map((person) => person.profile.userId),
      ...followedUserIds,
    };
    final suggestions = _profileSuggestions(excludedSuggestionIds);

    return Scaffold(
      body: RefreshIndicator.adaptive(
        onRefresh: () => _refreshProfile(ref),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          children: [
            me.when(
              data: (profile) => _ProfileHero(
                profile: profile,
                friends: followingPeople,
                followers: followerPeople,
                postsCount: _profileVisiblePostCount(
                  profile,
                  posts.valueOrNull ?? const [],
                  visibleRepostedPostIds,
                  visibleRepostActivityTimes,
                ),
                onSettingsPressed: () => _openProfileSettings(context, ref, me),
                onMessagesPressed: () => context.push('/messages'),
                onNotificationsPressed: () {
                  ref.read(unreadSocialNotificationsProvider.notifier).state =
                      0;
                  context.push('/notifications');
                },
                unreadMessageThreads: unreadMessageThreads,
                unreadNotifications: unreadNotifications,
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => const SizedBox.shrink(),
            ),
            const SizedBox(height: 24),
            Text(
              'Suggested for you',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            if (suggestions.isEmpty)
              const _NoSuggestionsCard()
            else
              SizedBox(
                height: 134,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: suggestions.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, index) => _SuggestedPersonCard(
                    person: suggestions[index],
                    onTap: () {
                      final person = suggestions[index];
                      context.push(
                        '/profile/${person.userId}',
                        extra: person.profile,
                      );
                    },
                  ),
                ),
              ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Your posts',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                FilledButton.icon(
                  style: tydesPostButtonStyle(),
                  onPressed: () => showCreatePostSheet(
                    context,
                    spots.valueOrNull ?? const [],
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Post'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            me.when(
              data: (profile) => posts.when(
                data: (items) => _ProfilePostFeed(
                  profile: profile,
                  allPosts: items,
                  posts: items
                      .where((post) => post.userId == profile.id)
                      .toList(),
                  spots: spots.valueOrNull ?? const [],
                  repostedPostIds: visibleRepostedPostIds,
                  repostActivityTimes: visibleRepostActivityTimes,
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Text('Could not load posts: $error'),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.profile,
    required this.friends,
    required this.followers,
    required this.postsCount,
    required this.unreadMessageThreads,
    required this.unreadNotifications,
    required this.onSettingsPressed,
    required this.onMessagesPressed,
    required this.onNotificationsPressed,
  });

  final UserProfile profile;
  final List<ProfilePerson> friends;
  final List<ProfilePerson> followers;
  final int postsCount;
  final int unreadMessageThreads;
  final int unreadNotifications;
  final VoidCallback onSettingsPressed;
  final VoidCallback onMessagesPressed;
  final VoidCallback onNotificationsPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF064D63), Color(0xFF0AAFB3), Color(0xFFE9B872)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: CircleAvatar(
                      radius: 34,
                      backgroundColor: Colors.white,
                      backgroundImage: profile.avatarUrl == null
                          ? null
                          : NetworkImage(profile.avatarUrl!),
                      child: profile.avatarUrl == null
                          ? Text(
                              profile.displayName.characters.first,
                              style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF087E8B),
                              ),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 56),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _ProfileStat(
                            value: postsCount.toString(),
                            label: 'Posts',
                          ),
                          _ProfileStat(
                            value: friends.length.toString(),
                            label: 'Following',
                            onTap: () => showProfilePeopleSheet(
                              context: context,
                              title: 'Following',
                              people: friends,
                              onProfileTap: (person) => context.push(
                                '/profile/${person.userId}',
                                extra: person,
                              ),
                              emptyText: 'Not following anyone yet.',
                            ),
                          ),
                          _ProfileStat(
                            value: followers.length.toString(),
                            label: 'Followers',
                            onTap: () => showProfilePeopleSheet(
                              context: context,
                              title: 'Followers',
                              people: followers,
                              onProfileTap: (person) => context.push(
                                '/profile/${person.userId}',
                                extra: person,
                              ),
                              emptyText: 'No followers yet.',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      profile.displayName,
                      style: Theme.of(
                        context,
                      ).textTheme.headlineMedium?.copyWith(color: Colors.white),
                    ),
                  ),
                  if (profile.premium) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.24),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.verified_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Premium',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '@${profile.handle} • ${profile.homeRegion} • ${_skillLabel(profile.surfSkill)}',
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 12),
              Text(profile.bio, style: const TextStyle(color: Colors.white)),
            ],
          ),
          Positioned(
            top: 0,
            right: 0,
            child: Column(
              children: [
                _ProfileHeroIconButton(
                  onPressed: onSettingsPressed,
                  tooltip: 'Profile settings',
                  icon: Icons.settings_outlined,
                ),
                const SizedBox(height: 8),
                _ProfileHeroIconButton(
                  onPressed: onMessagesPressed,
                  tooltip: 'Direct messages',
                  icon: Icons.mail_outline_rounded,
                  badgeCount: unreadMessageThreads,
                ),
                const SizedBox(height: 8),
                _ProfileHeroIconButton(
                  onPressed: onNotificationsPressed,
                  tooltip: 'Notifications',
                  icon: Icons.notifications_none_rounded,
                  badgeCount: unreadNotifications,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileHeroIconButton extends StatelessWidget {
  const _ProfileHeroIconButton({
    required this.onPressed,
    required this.tooltip,
    required this.icon,
    this.badgeCount,
  });

  final VoidCallback onPressed;
  final String tooltip;
  final IconData icon;
  final int? badgeCount;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          onPressed: onPressed,
          tooltip: tooltip,
          style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.14),
            foregroundColor: Colors.white,
            side: BorderSide(color: Colors.white.withValues(alpha: 0.24)),
          ),
          icon: Icon(icon),
        ),
        if (badgeCount != null && badgeCount! > 0)
          Positioned(
            top: -2,
            right: -2,
            child: Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: Text(
                badgeCount!.toString(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

int _profileVisiblePostCount(
  UserProfile profile,
  List<SocialPostModel> posts,
  List<String> repostedPostIds,
  Map<String, DateTime> repostActivityTimes,
) {
  return posts.where((post) => post.userId == profile.id).length +
      repostedItemsForProfile(
        posts: posts,
        profileUserId: profile.id,
        currentUserId: profile.id,
        myRepostedPostIds: repostedPostIds,
        myRepostActivityTimes: repostActivityTimes,
      ).length;
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({required this.value, required this.label, this.onTap});

  final String value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Column(
          children: [
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

List<ProfilePerson> _profileFriendPeople(
  List<FriendProfileModel> friends,
  Set<String> followedUserIds,
  Set<String> hiddenFollowingUserIds,
) {
  final people = friends
      .where((friend) => !hiddenFollowingUserIds.contains(friend.id))
      .map(
        (friend) => ProfilePerson(
          profile: PublicProfilePreview(
            userId: friend.id,
            displayName: friend.displayName,
            handle: _handleFromName(friend.displayName),
            subtitle: friend.vibe,
          ),
          subtitle: friend.homeRegion,
          forceFollowing: true,
        ),
      )
      .toList();

  final existingIds = people.map((person) => person.profile.userId).toSet();
  for (final userId in followedUserIds) {
    if (existingIds.contains(userId) ||
        hiddenFollowingUserIds.contains(userId)) {
      continue;
    }
    people.add(
      ProfilePerson(
        profile: _profilePreviewFromUserId(userId),
        subtitle: _profilePreviewFromUserId(userId).location ?? 'Following',
        forceFollowing: true,
      ),
    );
  }

  return people;
}

List<ProfilePerson> _profileFollowerPeople(Set<String> hiddenFollowerUserIds) {
  final names = [
    'Ari Dawn',
    'Lina Reef',
    'Jo Tide',
    'Maya Surfer',
    'Kai Point',
    'Nina Sets',
    'Sam Sandbar',
    'Rafa Dawn',
    'Ella Glassy',
    'Noah Lefts',
    'Milo Tide',
    'Sari Peaks',
    'Ben Offshore',
    'Cleo Foam',
  ];

  return names
      .map(
        (name) => ProfilePerson(
          profile: PublicProfilePreview(
            userId: name == 'Ari Dawn'
                ? 'friend_ari'
                : 'follower_${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}',
            displayName: name,
            handle: _handleFromName(name),
            subtitle: 'Surf traveler on Tydes',
          ),
          subtitle: 'Follower',
          forceFollowerActions: true,
        ),
      )
      .where((person) => !hiddenFollowerUserIds.contains(person.profile.userId))
      .toList();
}

PublicProfilePreview _profilePreviewFromUserId(String userId) {
  for (final profile in _knownProfilePreviews) {
    if (profile.userId == userId) return profile;
  }
  final name = userId
      .replaceFirst(RegExp(r'^(friend|suggested|random|follower)_'), '')
      .split('_')
      .where((part) => part.isNotEmpty)
      .map(
        (part) => '${part.characters.first.toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
  return PublicProfilePreview(
    userId: userId,
    displayName: name.isEmpty ? 'Surfer' : name,
    handle: _handleFromName(name),
    subtitle: 'Surf traveler on Tydes',
  );
}

const _knownProfilePreviews = [
  PublicProfilePreview(
    userId: 'friend_ari',
    displayName: 'Ari Dawn',
    handle: 'aridawn',
    subtitle: 'Intermediate, early sessions, shares rides.',
    location: 'Uluwatu',
  ),
  PublicProfilePreview(
    userId: 'friend_lina',
    displayName: 'Lina Reef',
    handle: 'linareef',
    subtitle: 'Longboard mornings, coffee after.',
    location: 'Canggu',
  ),
  PublicProfilePreview(
    userId: 'friend_jo',
    displayName: 'Jo Tide',
    handle: 'jotide',
    subtitle: 'Looking for reef buddies and clean rights.',
    location: 'Siargao',
  ),
  PublicProfilePreview(
    userId: 'friend_maya',
    displayName: 'Maya Surfer',
    handle: 'mayasurfer',
    subtitle: 'Photos, reef notes, and mellow dawn missions.',
    location: 'Uluwatu',
  ),
  PublicProfilePreview(
    userId: 'friend_kai',
    displayName: 'Kai Glass',
    handle: 'kaiglass',
    subtitle: 'Point-break addict, usually chasing long walls.',
    location: 'Byron Bay',
  ),
  PublicProfilePreview(
    userId: 'suggested_tara_sets',
    displayName: 'Tara Sets',
    handle: 'tarasets',
    subtitle: 'Followed by Ari Dawn',
    location: 'Canggu',
  ),
  PublicProfilePreview(
    userId: 'suggested_reef_milo',
    displayName: 'Reef Milo',
    handle: 'reefmilo',
    subtitle: 'Followed by Lina Reef',
    location: 'Siargao',
  ),
  PublicProfilePreview(
    userId: 'suggested_ella_tide',
    displayName: 'Ella Tide',
    handle: 'ellatide',
    subtitle: 'Followed by Jo Tide',
    location: 'Uluwatu',
  ),
  PublicProfilePreview(
    userId: 'random_cleo_foam',
    displayName: 'Cleo Foam',
    handle: 'cleofoam',
    subtitle: 'Popular in Bali',
    location: 'Bali',
  ),
  PublicProfilePreview(
    userId: 'random_taj_current',
    displayName: 'Taj Current',
    handle: 'tajcurrent',
    subtitle: 'Surfs near you',
    location: 'Bali',
  ),
  PublicProfilePreview(
    userId: 'random_ivy_reef',
    displayName: 'Ivy Reef',
    handle: 'ivyreef',
    subtitle: 'New to Tydes',
    location: 'Uluwatu',
  ),
];

String? _handleFromName(String? name) {
  if (name == null || name.trim().isEmpty) return null;
  return name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

class _ProfileSettingsSheet extends StatelessWidget {
  const _ProfileSettingsSheet({
    required this.profile,
    required this.premium,
    required this.selectedLocale,
    required this.onLocaleChanged,
    required this.onEditProfile,
    required this.onManagePremium,
    required this.onLogout,
    required this.onDeleteAccount,
  });

  final UserProfile? profile;
  final bool premium;
  final Locale selectedLocale;
  final ValueChanged<Locale> onLocaleChanged;
  final VoidCallback? onEditProfile;
  final VoidCallback onManagePremium;
  final VoidCallback onLogout;
  final VoidCallback onDeleteAccount;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD5D0C6),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Profile settings',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 14),
            if (profile != null) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit profile'),
                subtitle: Text('@${profile!.handle}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: onEditProfile,
              ),
              const Divider(),
            ],
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                premium ? Icons.verified : Icons.workspace_premium_outlined,
              ),
              title: Text(premium ? 'Premium active' : 'Manage premium'),
              subtitle: const Text('Forecast access and future upgrades'),
              trailing: const Icon(Icons.chevron_right),
              onTap: onManagePremium,
            ),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.language),
              title: const Text('Language'),
              subtitle: const Text('App display language'),
              trailing: SegmentedButton<Locale>(
                segments: const [
                  ButtonSegment<Locale>(value: Locale('en'), label: Text('EN')),
                  ButtonSegment<Locale>(value: Locale('id'), label: Text('ID')),
                ],
                selected: {selectedLocale},
                onSelectionChanged: (selection) =>
                    onLocaleChanged(selection.first),
              ),
            ),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.logout),
              title: const Text('Log out'),
              subtitle: const Text('Sign in with a different account'),
              onTap: onLogout,
            ),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.delete_forever_outlined,
                color: Color(0xFFB3261E),
              ),
              title: const Text(
                'Delete account',
                style: TextStyle(color: Color(0xFFB3261E)),
              ),
              subtitle: const Text('Remove this test account and reuse email'),
              onTap: onDeleteAccount,
            ),
          ],
        ),
      ),
    );
  }
}

class _EditProfileSheet extends ConsumerStatefulWidget {
  const _EditProfileSheet({required this.profile});

  final UserProfile profile;

  @override
  ConsumerState<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends ConsumerState<_EditProfileSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _handleController;
  late final TextEditingController _locationController;
  late final TextEditingController _bioController;
  final _imagePicker = ImagePicker();
  String _skill = 'intermediate';
  String? _handleError;
  XFile? _avatarImage;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.displayName);
    _handleController = TextEditingController(text: widget.profile.handle);
    _locationController = TextEditingController(
      text: widget.profile.homeRegion,
    );
    _bioController = TextEditingController(text: widget.profile.bio);
    _skill = widget.profile.surfSkill;
    _handleController.addListener(() {
      if (_handleError != null) {
        setState(() => _handleError = null);
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _handleController.dispose();
    _locationController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final displayName = _nameController.text.trim();
    final handle = _handleController.text.trim().replaceAll('@', '');
    final location = _locationController.text.trim();
    final bio = _bioController.text.trim();

    if (displayName.isEmpty || handle.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and @tag are required.')),
      );
      return;
    }

    setState(() {
      _handleError = null;
      _saving = true;
    });
    try {
      String? avatarUrl = widget.profile.avatarUrl;
      final avatarImage = _avatarImage;
      if (avatarImage != null) {
        final thumbnail = await _createProfileThumbnail(avatarImage);
        final uploaded = await ref
            .read(surfRepositoryProvider)
            .uploadPostPhoto(image: avatarImage, thumbnail: thumbnail);
        avatarUrl = uploaded.thumbnailUrl;
      }
      await ref
          .read(surfRepositoryProvider)
          .updateProfile(
            displayName: displayName,
            handle: handle,
            bio: bio,
            surfSkill: _skill,
            homeRegion: location,
            avatarUrl: avatarUrl,
          );
      ref.invalidate(meProvider);
      ref.invalidate(socialPostsProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      final message = error.toString().replaceFirst('Bad state: ', '');
      if (_isHandleTakenMessage(message)) {
        setState(() => _handleError = 'Tag already taken');
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAvatar() async {
    final picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1400,
      imageQuality: 80,
      requestFullMetadata: false,
    );
    if (picked == null || !mounted) return;
    setState(() => _avatarImage = picked);
  }

  Future<XFile> _createProfileThumbnail(XFile source) async {
    final bytes = await source.readAsBytes();
    final decoded = image_tools.decodeImage(bytes);
    if (decoded == null) return source;

    final resized = image_tools.copyResizeCropSquare(decoded, size: 500);
    final encoded = image_tools.encodeJpg(resized, quality: 72);
    final tempDir = await getTemporaryDirectory();
    final path =
        '${tempDir.path}/profile_thumb_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final file = await File(path).writeAsBytes(encoded, flush: true);
    return XFile(
      file.path,
      name: file.uri.pathSegments.last,
      mimeType: 'image/jpeg',
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + bottomInset),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD5D0C6),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Edit profile',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Center(
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 42,
                      backgroundColor: const Color(0xFFE6F3F1),
                      backgroundImage: _avatarImage != null
                          ? FileImage(File(_avatarImage!.path))
                          : (widget.profile.avatarUrl != null
                                    ? NetworkImage(widget.profile.avatarUrl!)
                                    : null)
                                as ImageProvider<Object>?,
                      child:
                          _avatarImage == null &&
                              widget.profile.avatarUrl == null
                          ? Text(
                              widget.profile.displayName.characters.first,
                              style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF087E8B),
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: _saving ? null : _pickAvatar,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Change profile picture'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Your display name',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _handleController,
                decoration: InputDecoration(
                  labelText: '@tag',
                  hintText: 'yourtag',
                  prefixText: '@',
                  errorText: _handleError,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _locationController,
                textCapitalization: TextCapitalization.words,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: 'Location (optional)',
                  hintText: 'Bali, Gold Coast, Canggu...',
                ),
              ),
              const SizedBox(height: 14),
              Text('Surf level', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment<String>(
                    value: 'beginner',
                    label: Text('Beginner'),
                  ),
                  ButtonSegment<String>(
                    value: 'intermediate',
                    label: Text('Skilled'),
                  ),
                  ButtonSegment<String>(value: 'pro', label: Text('Pro')),
                ],
                selected: {_skill},
                onSelectionChanged: _saving
                    ? null
                    : (selection) => setState(() => _skill = selection.first),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _bioController,
                maxLines: 4,
                maxLength: 180,
                decoration: const InputDecoration(
                  labelText: 'Bio',
                  hintText:
                      'Tell people what kind of waves and surf trips you are into.',
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving...' : 'Save profile'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

bool _isHandleTakenMessage(String message) {
  return message.toLowerCase().contains('tag is already taken') ||
      message.toLowerCase().contains('tag already taken');
}

String _skillLabel(String skill) {
  switch (skill) {
    case 'beginner':
      return 'Beginner';
    case 'pro':
      return 'Pro';
    default:
      return 'Skilled';
  }
}

class _SuggestedPersonCard extends StatelessWidget {
  const _SuggestedPersonCard({required this.person, required this.onTap});

  final _SuggestedPerson person;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 116,
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: tydesAvatarBackground,
                  child: Text(
                    person.initial,
                    style: const TextStyle(
                      color: tydesAvatarForeground,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  person.displayName,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  person.reason,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(height: 1.15),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

List<_SuggestedPerson> _profileSuggestions(Set<String> excludedIds) {
  return _suggestedPeople
      .where((person) => !excludedIds.contains(person.userId))
      .take(8)
      .toList();
}

const _suggestedPeople = [
  _SuggestedPerson(
    userId: 'suggested_tara_sets',
    displayName: 'Tara Sets',
    initial: 'T',
    reason: 'Followed by Ari Dawn',
    handle: 'tarasets',
    location: 'Canggu',
  ),
  _SuggestedPerson(
    userId: 'suggested_reef_milo',
    displayName: 'Reef Milo',
    initial: 'R',
    reason: 'Followed by Lina Reef',
    handle: 'reefmilo',
    location: 'Siargao',
  ),
  _SuggestedPerson(
    userId: 'suggested_ella_tide',
    displayName: 'Ella Tide',
    initial: 'E',
    reason: 'Followed by Jo Tide',
    handle: 'ellatide',
    location: 'Uluwatu',
  ),
  _SuggestedPerson(
    userId: 'suggested_noah_glass',
    displayName: 'Noah Glass',
    initial: 'N',
    reason: 'Followed by Maya Surfer',
    handle: 'noahglass',
    location: 'Arugam Bay',
  ),
  _SuggestedPerson(
    userId: 'suggested_sari_peak',
    displayName: 'Sari Peak',
    initial: 'S',
    reason: 'Followed by Kai Glass',
    handle: 'saripeak',
    location: 'Bukit',
  ),
  _SuggestedPerson(
    userId: 'random_cleo_foam',
    displayName: 'Cleo Foam',
    initial: 'C',
    reason: 'New to Tydes',
    handle: 'cleofoam',
    location: 'Bali',
  ),
  _SuggestedPerson(
    userId: 'random_taj_current',
    displayName: 'Taj Current',
    initial: 'T',
    reason: 'New to Tydes',
    handle: 'tajcurrent',
    location: 'Bali',
  ),
  _SuggestedPerson(
    userId: 'random_ivy_reef',
    displayName: 'Ivy Reef',
    initial: 'I',
    reason: 'New to Tydes',
    handle: 'ivyreef',
    location: 'Uluwatu',
  ),
];

class _SuggestedPerson {
  const _SuggestedPerson({
    required this.userId,
    required this.displayName,
    required this.initial,
    required this.reason,
    required this.handle,
    required this.location,
  });

  final String userId;
  final String displayName;
  final String initial;
  final String reason;
  final String handle;
  final String location;

  PublicProfilePreview get profile => PublicProfilePreview(
    userId: userId,
    displayName: displayName,
    handle: handle,
    subtitle: reason,
    location: location,
  );
}

class _NoSuggestionsCard extends StatelessWidget {
  const _NoSuggestionsCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'You followed everyone suggested for now.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _ProfilePostFeed extends StatelessWidget {
  const _ProfilePostFeed({
    required this.profile,
    required this.allPosts,
    required this.posts,
    required this.spots,
    required this.repostedPostIds,
    required this.repostActivityTimes,
  });

  final UserProfile profile;
  final List<SocialPostModel> allPosts;
  final List<SocialPostModel> posts;
  final List<SpotModel> spots;
  final List<String> repostedPostIds;
  final Map<String, DateTime> repostActivityTimes;

  @override
  Widget build(BuildContext context) {
    final reposts = repostedItemsForProfile(
      posts: allPosts,
      profileUserId: profile.id,
      currentUserId: profile.id,
      myRepostedPostIds: repostedPostIds,
      myRepostActivityTimes: repostActivityTimes,
    );
    if (posts.isEmpty && reposts.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const Icon(Icons.forum_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Your posts, photos, and surf notes will show up here.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final items = [
      for (final item in reposts) _ProfilePostFeedItem.repost(item),
      for (final post in posts) _ProfilePostFeedItem.post(post),
    ]..sort((a, b) => b.activityAt.compareTo(a.activityAt));

    return Column(
      children: [
        for (final item in items)
          Padding(
            key: ValueKey(item.key),
            padding: const EdgeInsets.only(bottom: 14),
            child: _ProfilePostCard(
              profile: profile,
              post: item.post,
              spots: spots,
              repostHeader: item.repostHeader,
              usePostAuthor: item.repostHeader != null,
            ),
          ),
      ],
    );
  }
}

class _ProfilePostFeedItem {
  const _ProfilePostFeedItem({
    required this.post,
    required this.activityAt,
    required this.key,
    this.repostHeader,
  });

  factory _ProfilePostFeedItem.post(SocialPostModel post) =>
      _ProfilePostFeedItem(
        post: post,
        activityAt: _profilePostCreatedAt(post),
        key: 'profile_post_${post.id}',
      );

  factory _ProfilePostFeedItem.repost(RepostedPostItem item) =>
      _ProfilePostFeedItem(
        post: item.post,
        activityAt: item.activityAt,
        key: 'profile_repost_${item.header}_${item.post.id}',
        repostHeader: item.header,
      );

  final SocialPostModel post;
  final DateTime activityAt;
  final String key;
  final String? repostHeader;
}

DateTime _profilePostCreatedAt(SocialPostModel post) {
  return DateTime.tryParse(post.createdAt) ??
      DateTime.fromMillisecondsSinceEpoch(0);
}

class _ProfilePostCard extends StatelessWidget {
  const _ProfilePostCard({
    required this.profile,
    required this.post,
    required this.spots,
    this.repostHeader,
    this.usePostAuthor = false,
  });

  final UserProfile profile;
  final SocialPostModel post;
  final List<SpotModel> spots;
  final String? repostHeader;
  final bool usePostAuthor;

  @override
  Widget build(BuildContext context) {
    final spot = _profileSpotForId(spots, post.spotId);
    final isSurfInvite = _profileIsSurfInvite(post);
    final authorName = usePostAuthor ? post.authorName : profile.displayName;
    final authorHandle = usePostAuthor ? post.authorHandle : profile.handle;
    final authorAvatarUrl = usePostAuthor
        ? post.authorAvatarUrl
        : profile.avatarUrl;
    final authorPremium = usePostAuthor ? post.authorPremium : profile.premium;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (repostHeader != null) ...[
              _ProfileRepostHeader(label: repostHeader!),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: Colors.white,
                  backgroundImage: authorAvatarUrl == null
                      ? null
                      : NetworkImage(authorAvatarUrl),
                  child: authorAvatarUrl == null
                      ? Text(authorName.characters.first)
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
                              authorName,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (authorPremium) ...[
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.verified_rounded,
                              size: 16,
                              color: Color(0xFF2AA7A1),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        '@${authorHandle ?? ''} • ${_profileVisibilityLabel(post.visibility)} ${isSurfInvite ? 'event' : 'post'}',
                      ),
                    ],
                  ),
                ),
                if (spot != null)
                  ActionChip(
                    avatar: const Icon(Icons.place_outlined, size: 16),
                    label: Text(spot.name),
                    onPressed: () => context.push('/spot/${spot.id}'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (post.media.isNotEmpty) ...[
              SocialPostMediaCarousel(media: post.media, borderRadius: 20),
              const SizedBox(height: 12),
            ],
            if (post.body.isNotEmpty)
              Text(post.body, style: Theme.of(context).textTheme.bodyLarge),
            if (isSurfInvite) ...[
              if (post.body.isNotEmpty) const SizedBox(height: 14),
              SurfInviteActions(post: post, spot: spot),
            ],
            const SizedBox(height: 12),
            PostEngagementBar(post: post),
          ],
        ),
      ),
    );
  }
}

class _ProfileRepostHeader extends StatelessWidget {
  const _ProfileRepostHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.autorenew_rounded, size: 18, color: scheme.primary),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

SpotModel? _profileSpotForId(List<SpotModel> spots, String? spotId) {
  if (spotId == null) return null;
  for (final spot in spots) {
    if (spot.id == spotId) return spot;
  }
  return null;
}

String _profileVisibilityLabel(String visibility) {
  switch (visibility) {
    case 'followers':
      return 'Followers';
    default:
      return 'Public';
  }
}

bool _profileIsSurfInvite(SocialPostModel post) {
  return post.postType == 'surf_plan' || post.postType == 'looking_for_buddy';
}
