import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as image_tools;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/billing/revenuecat_service.dart';
import '../../core/legal/legal_links.dart';
import '../../core/network/api_error_message.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../../core/widgets/feed_refresh_indicator.dart';
import '../../core/theme/appearance_settings.dart';
import '../home/home_page.dart';
import '../alerts/alert_state.dart';
import '../social/direct_messages_page.dart';
import '../social/notifications_page.dart';
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

final blockedSocialProfilesProvider = FutureProvider((ref) {
  ref.watch(socialRefreshKeyProvider);
  ref.watch(blockedUserIdsProvider);
  return ref.watch(surfRepositoryProvider).fetchBlockedSocialProfiles();
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
        onBlockedUsers: () {
          Navigator.of(context).pop();
          _openBlockedUsers(context, ref);
        },
        onAdminDashboard:
            me.valueOrNull?.email.toLowerCase().endsWith('@tydes.io') == true
            ? () {
                Navigator.of(context).pop();
                context.push('/admin');
              }
            : null,
        onLegalSupport: () {
          Navigator.of(context).pop();
          _openLegalSupport(context);
        },
        onLogout: () async {
          await ref.read(surfRepositoryProvider).logout();
          await ref.read(revenueCatServiceProvider).logOut();
          ref.invalidate(alertsProvider);
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
          context.go('/login');
        },
        onDeleteAccount: () async {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Delete account?'),
              content: const Text(
                'Permanently delete your Tydes account and its content. You can create a new account with the same email afterward. Cancel any active subscription through Manage subscription or your app store before deleting.',
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
          try {
            await ref.read(surfRepositoryProvider).deleteAccount();
          } catch (error) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    error.toString().replaceFirst('Bad state: ', ''),
                  ),
                ),
              );
            }
            return;
          }
          await ref.read(revenueCatServiceProvider).logOut();
          ref.invalidate(alertsProvider);
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
          context.go('/login');
        },
      ),
    );
  }

  Future<void> _openBlockedUsers(BuildContext context, WidgetRef ref) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _BlockedUsersSheet(),
    );
  }

  Future<void> _openLegalSupport(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _LegalSupportSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final friends = ref.watch(friendsProvider);
    final socialProfiles = ref.watch(socialProfilesProvider);
    final posts = ref.watch(socialPostsProvider);
    final spots = ref.watch(spotsProvider);
    final followedUserIds = ref.watch(followedUserIdsProvider);
    final followerUserIds = ref.watch(followerUserIdsProvider);
    final blockedUserIds = ref.watch(blockedUserIdsProvider);
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
    ref.watch(socialRelationshipHydrationProvider);
    final followingPeople = _profileFriendPeople(
      friends.valueOrNull ?? const [],
      followedUserIds,
      hiddenFollowingUserIds,
      socialProfiles.valueOrNull ?? const [],
    );
    final followerPeople = _profileFollowerPeople(
      followerUserIds,
      hiddenFollowerUserIds,
      socialProfiles.valueOrNull ?? const [],
    );
    final excludedSuggestionIds = {
      ...followingPeople.map((person) => person.profile.userId),
      ...followerPeople.map((person) => person.profile.userId),
      ...followedUserIds,
      ...blockedUserIds,
    };
    final suggestions = _profileSuggestions(
      socialProfiles.valueOrNull ?? const [],
      excludedSuggestionIds,
    );

    return Scaffold(
      body: FeedRefreshIndicator(
        onRefresh: () => _refreshProfile(ref),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          children: [
            me.when(
              skipLoadingOnReload: true,
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
                  ref.invalidate(socialNotificationsProvider);
                  ref.read(unreadSocialNotificationsProvider.notifier).state =
                      0;
                  context.push('/notifications');
                },
                unreadMessageThreads: unreadMessageThreads,
                unreadNotifications: unreadNotifications,
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _SignedOutProfileCard(
                message: _profileErrorMessage(error),
                onSignIn: () => context.go('/login'),
              ),
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
                  onPressed: me.hasError
                      ? () => context.go('/login')
                      : () => showCreatePostSheet(
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
              skipLoadingOnReload: true,
              data: (profile) => posts.when(
                skipLoadingOnReload: true,
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
                error: (error, _) =>
                    Text(friendlyLoadErrorMessage(error, label: 'posts')),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => const _SignedOutPostsCard(),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignedOutProfileCard extends StatelessWidget {
  const _SignedOutProfileCard({required this.message, required this.onSignIn});

  final String message;
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, color: scheme.primary, size: 28),
            const SizedBox(height: 12),
            Text(
              'Sign in to view your profile',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(
                color: Theme.of(context).brightness == Brightness.dark
                    ? scheme.onSurfaceVariant
                    : const Color(0xFF5D686C),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onSignIn, child: const Text('Sign in')),
          ],
        ),
      ),
    );
  }
}

class _SignedOutPostsCard extends StatelessWidget {
  const _SignedOutPostsCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(18),
        child: Text('Sign in to see and create your posts.'),
      ),
    );
  }
}

String _profileErrorMessage(Object error) {
  final message = error.toString().replaceFirst('Bad state: ', '');
  if (message.toLowerCase().contains('session expired')) {
    return 'Your session expired after the backend update. Sign in again and your real account will load.';
  }
  return 'We could not load your profile right now. Sign in again to refresh your session.';
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
    return TydesProfileCover(
      coverUrl: profile.coverUrl,
      child: Padding(
        padding: const EdgeInsets.all(20),
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
                      child: TydesProfileAvatar(
                        size: 68,
                        displayName: profile.displayName,
                        imageUrl: profile.avatarUrl,
                        backgroundColor: Colors.white,
                        foregroundColor: tydesAvatarForeground,
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 56),
                        child: ProfileStatsRow(
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
                Padding(
                  padding: const EdgeInsets.only(right: 64),
                  child: Text(
                    profile.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.headlineMedium?.copyWith(color: Colors.white),
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(right: 64),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '@${profile.handle} • ${profile.homeRegion} • ${_skillLabel(profile.surfSkill)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      if (profile.premium)
                        TextButton.icon(
                          onPressed: () => context.push('/paywall'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.18,
                            ),
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.24),
                            ),
                            shape: const StadiumBorder(),
                            minimumSize: const Size(0, 28),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                            textStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          icon: const Icon(Icons.verified_rounded, size: 14),
                          label: const Text('Premium'),
                        ),
                    ],
                  ),
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
  List<SocialProfileModel> socialProfiles,
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
    final profile = _profilePreviewFromUserId(userId, socialProfiles);
    people.add(
      ProfilePerson(
        profile: profile,
        subtitle: profile.location ?? 'Following',
        forceFollowing: true,
      ),
    );
  }

  return people;
}

List<ProfilePerson> _profileFollowerPeople(
  Set<String> followerUserIds,
  Set<String> hiddenFollowerUserIds,
  List<SocialProfileModel> socialProfiles,
) {
  final people = <ProfilePerson>[];
  for (final userId in followerUserIds) {
    if (hiddenFollowerUserIds.contains(userId)) {
      continue;
    }
    people.add(
      ProfilePerson(
        profile: _profilePreviewFromUserId(userId, socialProfiles),
        subtitle: 'Follower',
        forceFollowerActions: true,
      ),
    );
  }
  return people;
}

PublicProfilePreview _profilePreviewFromUserId(
  String userId,
  List<SocialProfileModel> socialProfiles,
) {
  for (final profile in socialProfiles) {
    if (profile.userId != userId) continue;
    return PublicProfilePreview(
      userId: profile.userId,
      displayName: profile.displayName,
      handle: profile.handle,
      avatarUrl: profile.avatarUrl,
      coverUrl: profile.coverUrl,
      premium: profile.premium,
      subtitle: profile.subtitle,
      location: profile.location,
      surfSkill: profile.surfSkill ?? 'beginner',
    );
  }
  return PublicProfilePreview(
    userId: userId,
    displayName: 'Tydes surfer',
    subtitle: 'Surf traveler on Tydes',
  );
}

String? _handleFromName(String? name) {
  if (name == null || name.trim().isEmpty) return null;
  return name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

class _ProfileSettingsSheet extends StatelessWidget {
  const _ProfileSettingsSheet({
    required this.profile,
    required this.premium,
    required this.onEditProfile,
    required this.onManagePremium,
    required this.onBlockedUsers,
    required this.onAdminDashboard,
    required this.onLegalSupport,
    required this.onLogout,
    required this.onDeleteAccount,
  });

  final UserProfile? profile;
  final bool premium;
  final VoidCallback? onEditProfile;
  final VoidCallback onManagePremium;
  final VoidCallback onBlockedUsers;
  final VoidCallback? onAdminDashboard;
  final VoidCallback onLegalSupport;
  final VoidCallback onLogout;
  final VoidCallback onDeleteAccount;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
              const AppearanceSettingsTile(contentPadding: EdgeInsets.zero),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.block_outlined),
                title: const Text('Blocked surfers'),
                subtitle: const Text('View or unblock accounts'),
                trailing: const Icon(Icons.chevron_right),
                onTap: onBlockedUsers,
              ),
              const Divider(),
              if (onAdminDashboard != null) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.admin_panel_settings_outlined),
                  title: const Text('Admin dashboard'),
                  subtitle: const Text('View registered Tydes accounts'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: onAdminDashboard,
                ),
                const Divider(),
              ],
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.policy_outlined),
                title: const Text('Legal & support'),
                subtitle: const Text('Privacy, terms, safety, and contact'),
                trailing: const Icon(Icons.chevron_right),
                onTap: onLegalSupport,
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
                leading: Icon(
                  Icons.delete_forever_outlined,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Delete account',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                subtitle: const Text('Permanently delete your account'),
                onTap: onDeleteAccount,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LegalSupportSheet extends StatelessWidget {
  const _LegalSupportSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: ListView(
          shrinkWrap: true,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.brightness == Brightness.dark
                      ? theme.colorScheme.outlineVariant
                      : const Color(0xFFD5D0C6),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('Legal & support', style: theme.textTheme.titleLarge),
            const SizedBox(height: 14),
            _LegalSupportTile(
              icon: Icons.privacy_tip_outlined,
              title: 'Privacy Policy',
              subtitle: tydesPrivacyPolicyUrl,
              onTap: () => launchTydesPrivacyPolicy(context),
            ),
            const Divider(),
            _LegalSupportTile(
              icon: Icons.description_outlined,
              title: 'Terms of Use',
              subtitle: tydesTermsOfUseUrl,
              onTap: () => launchTydesTermsOfUse(context),
            ),
            const Divider(),
            _LegalSupportTile(
              icon: Icons.mail_outline_rounded,
              title: 'Contact support',
              subtitle: tydesSupportEmail,
              onTap: () => launchTydesSupportEmail(context),
            ),
            const SizedBox(height: 16),
            const _SafetyAndCommunityCard(),
          ],
        ),
      ),
    );
  }
}

class _LegalSupportTile extends StatelessWidget {
  const _LegalSupportTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.open_in_new_rounded),
      onTap: onTap,
    );
  }
}

class _SafetyAndCommunityCard extends StatelessWidget {
  const _SafetyAndCommunityCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      color: theme.brightness == Brightness.dark
          ? scheme.surfaceContainerHigh
          : const Color(0xFFFFF4E4),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: scheme.onSurface),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Safety disclaimer',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Surf forecasts, tide times, map locations, alerts, and Best Time Today are estimates for planning only. Conditions can change quickly. Check local hazards, tide, weather, and local advice before paddling out. Tydes is not for navigation or safety-critical decisions.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Tydes does not allow sexual services, nudity, harassment, hate, scams, or unsafe events. Use report and block if something feels wrong.',
            ),
          ],
        ),
      ),
    );
  }
}

class _BlockedUsersSheet extends ConsumerWidget {
  const _BlockedUsersSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final blockedIds = ref.watch(blockedUserIdsProvider);
    final blockedProfiles = ref.watch(blockedSocialProfilesProvider);
    ref.watch(socialRelationshipHydrationProvider);

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
                  color: theme.brightness == Brightness.dark
                      ? theme.colorScheme.outlineVariant
                      : const Color(0xFFD5D0C6),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('Blocked surfers', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'Blocked accounts cannot appear in your feed, search, or new-message picker.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: blockedProfiles.when(
                data: (profiles) {
                  final people = _blockedProfilePreviews(profiles, blockedIds);
                  if (people.isEmpty) return const _NoBlockedUsersCard();
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: people.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) =>
                        _BlockedUserTile(profile: people[index]),
                  );
                },
                loading: () {
                  if (blockedIds.isEmpty) return const _NoBlockedUsersCard();
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(child: CircularProgressIndicator()),
                  );
                },
                error: (_, _) {
                  final people = _blockedProfilePreviews(const [], blockedIds);
                  if (people.isEmpty) return const _NoBlockedUsersCard();
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: people.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) =>
                        _BlockedUserTile(profile: people[index]),
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

class _NoBlockedUsersCard extends StatelessWidget {
  const _NoBlockedUsersCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(18),
        child: Text('No blocked surfers.'),
      ),
    );
  }
}

class _BlockedUserTile extends ConsumerWidget {
  const _BlockedUserTile({required this.profile});

  final PublicProfilePreview profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            TydesProfileAvatar(
              size: 40,
              displayName: profile.displayName,
              imageUrl: profile.avatarUrl,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  Text(
                    (profile.handle ?? '').isEmpty
                        ? 'Blocked on Tydes'
                        : '@${profile.handle}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => _unblockProfile(context, ref, profile),
              child: const Text('Unblock'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _unblockProfile(
    BuildContext context,
    WidgetRef ref,
    PublicProfilePreview profile,
  ) async {
    await unblockSocialUser(ref, profile.userId);
    ref.invalidate(blockedSocialProfilesProvider);
    ref.invalidate(socialProfilesProvider);
    ref.invalidate(travelFeedPostsProvider);
    ref.invalidate(socialPostsProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('@${profile.handle ?? profile.displayName} unblocked.'),
      ),
    );
  }
}

List<PublicProfilePreview> _blockedProfilePreviews(
  List<SocialProfileModel> profiles,
  Set<String> blockedIds,
) {
  final byId = <String, PublicProfilePreview>{};
  for (final profile in profiles) {
    if (!blockedIds.contains(profile.userId)) continue;
    byId[profile.userId] = PublicProfilePreview(
      userId: profile.userId,
      displayName: profile.displayName,
      handle: profile.handle,
      avatarUrl: profile.avatarUrl,
      coverUrl: profile.coverUrl,
      premium: profile.premium,
      subtitle: profile.subtitle,
      location: profile.location,
      surfSkill: profile.surfSkill ?? 'beginner',
    );
  }
  for (final userId in blockedIds) {
    byId.putIfAbsent(userId, () => _profilePreviewFromUserId(userId, profiles));
  }
  return byId.values.toList()
    ..sort((a, b) => a.displayName.compareTo(b.displayName));
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
  Uint8List? _avatarBytes;
  XFile? _coverImage;
  Uint8List? _coverBytes;
  bool _removeCover = false;
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
      _showProfileErrorDialog('Name and @tag are required.');
      return;
    }
    if (displayName.length > 32) {
      _showProfileErrorDialog('Name must be 32 characters or fewer.');
      return;
    }
    if (handle.length > 20) {
      setState(() => _handleError = 'Use 20 characters or fewer');
      return;
    }

    setState(() {
      _handleError = null;
      _saving = true;
    });
    try {
      String? avatarUrl = widget.profile.avatarUrl;
      String? avatarMediaId;
      final avatarImage = _avatarImage;
      if (avatarImage != null) {
        final thumbnail = await _createProfileThumbnail(avatarImage);
        final uploaded = await ref
            .read(surfRepositoryProvider)
            .uploadPostPhoto(image: avatarImage, thumbnail: thumbnail);
        avatarUrl = uploaded.thumbnailUrl;
        avatarMediaId = uploaded.id;
      }
      String? coverUrl = _removeCover ? null : widget.profile.coverUrl;
      String? coverMediaId;
      final coverImage = _coverImage;
      if (coverImage != null) {
        final cover = await _createProfileCover(
          coverImage,
          width: 1600,
          height: 600,
          quality: 80,
          prefix: 'profile_cover',
        );
        final coverThumbnail = await _createProfileCover(
          coverImage,
          width: 800,
          height: 300,
          quality: 72,
          prefix: 'profile_cover_thumb',
        );
        final uploaded = await ref
            .read(surfRepositoryProvider)
            .uploadPostPhoto(image: cover, thumbnail: coverThumbnail);
        coverUrl = uploaded.url;
        coverMediaId = uploaded.id;
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
            avatarMediaId: avatarMediaId,
            coverUrl: coverUrl,
            coverMediaId: coverMediaId,
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
      _showProfileErrorDialog(message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showProfileErrorDialog(String message) {
    final isCommunityRulesError = message.toLowerCase().contains(
      'community rules',
    );
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isCommunityRulesError
              ? 'Tydes community guidelines'
              : 'Could not save profile',
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAvatar() async {
    final picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1400,
      imageQuality: 80,
      requestFullMetadata: false,
    );
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _avatarImage = picked;
      _avatarBytes = bytes;
    });
  }

  Future<void> _pickCover() async {
    final picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2400,
      imageQuality: 88,
      requestFullMetadata: false,
    );
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _coverImage = picked;
      _coverBytes = bytes;
      _removeCover = false;
    });
  }

  void _clearCover() {
    setState(() {
      _coverImage = null;
      _coverBytes = null;
      _removeCover = true;
    });
  }

  Future<XFile> _createProfileThumbnail(XFile source) async {
    final bytes = await source.readAsBytes();
    final decoded = image_tools.decodeImage(bytes);
    if (decoded == null) return source;

    final resized = image_tools.copyResizeCropSquare(decoded, size: 500);
    final encoded = image_tools.encodeJpg(resized, quality: 72);
    final name = 'profile_thumb_${DateTime.now().microsecondsSinceEpoch}.jpg';
    if (kIsWeb) {
      return XFile.fromData(encoded, name: name, mimeType: 'image/jpeg');
    }
    final tempDir = await getTemporaryDirectory();
    final path = '${tempDir.path}/$name';
    final file = await File(path).writeAsBytes(encoded, flush: true);
    return XFile(
      file.path,
      name: file.uri.pathSegments.last,
      mimeType: 'image/jpeg',
    );
  }

  Future<XFile> _createProfileCover(
    XFile source, {
    required int width,
    required int height,
    required int quality,
    required String prefix,
  }) async {
    final bytes = await source.readAsBytes();
    final decoded = image_tools.decodeImage(bytes);
    if (decoded == null) return source;

    final targetRatio = width / height;
    final sourceRatio = decoded.width / decoded.height;
    final cropWidth = sourceRatio > targetRatio
        ? (decoded.height * targetRatio).round()
        : decoded.width;
    final cropHeight = sourceRatio > targetRatio
        ? decoded.height
        : (decoded.width / targetRatio).round();
    final cropped = image_tools.copyCrop(
      decoded,
      x: ((decoded.width - cropWidth) / 2).round(),
      y: ((decoded.height - cropHeight) / 2).round(),
      width: cropWidth,
      height: cropHeight,
    );
    final resized = image_tools.copyResize(
      cropped,
      width: width,
      height: height,
    );
    final encoded = image_tools.encodeJpg(resized, quality: quality);
    final name = '${prefix}_${DateTime.now().microsecondsSinceEpoch}.jpg';
    if (kIsWeb) {
      return XFile.fromData(encoded, name: name, mimeType: 'image/jpeg');
    }
    final tempDir = await getTemporaryDirectory();
    final path = '${tempDir.path}/$name';
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
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
                    color: isDark
                        ? theme.colorScheme.outlineVariant
                        : const Color(0xFFD5D0C6),
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
                    TydesProfileAvatar(
                      size: 84,
                      displayName: widget.profile.displayName,
                      backgroundColor: isDark
                          ? theme.colorScheme.primaryContainer
                          : const Color(0xFFE6F3F1),
                      foregroundColor: isDark
                          ? theme.colorScheme.onPrimaryContainer
                          : tydesAvatarForeground,
                      imageUrl: widget.profile.avatarUrl,
                      image: _avatarBytes == null
                          ? null
                          : MemoryImage(_avatarBytes!),
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
              const SizedBox(height: 16),
              AspectRatio(
                aspectRatio: 8 / 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Color(0xFF064D63),
                              Color(0xFF0AAFB3),
                              Color(0xFFE9B872),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                      ),
                      if (_coverBytes != null)
                        Image.memory(_coverBytes!, fit: BoxFit.cover)
                      else if (!_removeCover &&
                          widget.profile.coverUrl != null &&
                          widget.profile.coverUrl!.isNotEmpty)
                        Image.network(
                          widget.profile.coverUrl!,
                          fit: BoxFit.cover,
                          webHtmlElementStrategy:
                              WebHtmlElementStrategy.fallback,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0x5C003B48), Color(0x26001319)],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                        ),
                      ),
                      if (_coverBytes == null &&
                          (_removeCover ||
                              (widget.profile.coverUrl == null ||
                                  widget.profile.coverUrl!.isEmpty)))
                        const Center(
                          child: Icon(
                            Icons.landscape_outlined,
                            color: Colors.white70,
                            size: 36,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _saving ? null : _pickCover,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: const Text('Change cover photo'),
                  ),
                  if (_coverBytes != null ||
                      (!_removeCover && widget.profile.coverUrl != null))
                    TextButton(
                      onPressed: _saving ? null : _clearCover,
                      child: const Text('Remove'),
                    ),
                ],
              ),
              Center(
                child: Text(
                  'Best size: 1600 × 600. Tydes crops it to fit every screen.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? theme.colorScheme.onSurfaceVariant
                        : const Color(0xFF65757A),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                maxLength: 32,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Your display name',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _handleController,
                maxLength: 20,
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

List<_SuggestedPerson> _profileSuggestions(
  List<SocialProfileModel> profiles,
  Set<String> excludedIds,
) {
  return profiles
      .where((profile) => !excludedIds.contains(profile.userId))
      .map(
        (profile) => _SuggestedPerson(
          userId: profile.userId,
          displayName: profile.displayName,
          initial: profile.displayName.trim().isEmpty
              ? '?'
              : profile.displayName.trim().characters.first.toUpperCase(),
          reason: profile.subtitle ?? 'New to Tydes',
          handle: profile.handle,
          location: profile.location,
        ),
      )
      .take(8)
      .toList();
}

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
  final String? handle;
  final String? location;

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
          'No other surfers have completed a profile yet.',
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

    return TydesDesktopPostWidth(
      child: Column(
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
      ),
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
    final ownsOriginalPost = post.userId == profile.id;
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
                TydesProfileAvatar(
                  size: 40,
                  displayName: authorName,
                  imageUrl: authorAvatarUrl,
                  backgroundColor: Colors.white,
                  foregroundColor: tydesAvatarForeground,
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
                SharePostButton(post: post, spot: spot),
                if (ownsOriginalPost) ...[
                  const SizedBox(width: 4),
                  OwnPostMenu(post: post),
                ],
              ],
            ),
            if (spot != null) ...[
              const SizedBox(height: 10),
              ActionChip(
                avatar: const Icon(Icons.place_outlined, size: 16),
                label: Text(spot.name),
                onPressed: () => context.push('/spot/${spot.id}'),
              ),
            ],
            const SizedBox(height: 12),
            if (post.media.isNotEmpty) ...[
              SocialPostMediaCarousel(media: post.media, borderRadius: 20),
              const SizedBox(height: 12),
            ],
            if (post.body.isNotEmpty) SocialPostBodyPreview(body: post.body),
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
