import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';
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

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final friends = ref.watch(friendsProvider);
    final posts = ref.watch(socialPostsProvider);
    final spots = ref.watch(spotsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            onPressed: () async {
              await showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (context) => _ProfileSettingsSheet(
                  premium: me.valueOrNull?.premium ?? false,
                  selectedLocale: ref.watch(localeProvider),
                  onLocaleChanged: (locale) =>
                      ref.read(localeProvider.notifier).state = locale,
                  onManagePremium: () {
                    Navigator.of(context).pop();
                    context.push('/paywall');
                  },
                  onLogout: () async {
                    await ref.read(surfRepositoryProvider).logout();
                    ref.invalidate(meProvider);
                    ref.invalidate(dashboardProvider);
                    ref.invalidate(homeAdsProvider);
                    ref.invalidate(spotsProvider);
                    ref.invalidate(spotForecastProvider);
                    ref.invalidate(spotTideProvider);
                    ref.invalidate(spotDetailBundleProvider);
                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                    context.push('/login');
                  },
                ),
              );
            },
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Profile settings',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          me.when(
            data: (profile) => _ProfileHero(
              profile: profile,
              friendsCount: friends.valueOrNull?.length ?? 0,
              postsCount:
                  posts.valueOrNull
                      ?.where((post) => post.userId == profile.id)
                      .length ??
                  0,
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Friends nearby',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton(onPressed: () {}, child: const Text('Find more')),
            ],
          ),
          const SizedBox(height: 10),
          friends.when(
            data: (items) => SizedBox(
              height: 124,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) =>
                    _FriendCard(friend: items[index]),
              ),
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Text('Could not load crew: $error'),
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
              TextButton(
                onPressed: () =>
                    ref.read(currentTabProvider.notifier).state = 0,
                child: const Text('Post in feed'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          me.when(
            data: (profile) => posts.when(
              data: (items) => _ProfilePostGrid(
                posts: items
                    .where((post) => post.userId == profile.id)
                    .toList(),
                spots: spots.valueOrNull ?? const [],
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Text('Could not load posts: $error'),
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.profile,
    required this.friendsCount,
    required this.postsCount,
  });

  final UserProfile profile;
  final int friendsCount;
  final int postsCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF082D35), Color(0xFF0D6F65), Color(0xFFE9B872)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Column(
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
                  child: Text(
                    profile.displayName.characters.first,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF0B6E6E),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              _ProfileStat(value: postsCount.toString(), label: 'Posts'),
              const SizedBox(width: 18),
              _ProfileStat(value: friendsCount.toString(), label: 'Friends'),
              const SizedBox(width: 18),
              const _ProfileStat(value: '14', label: 'Followers'),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            profile.displayName,
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(color: Colors.white),
          ),
          const SizedBox(height: 6),
          Text(
            '@${profile.email.split('@').first.replaceAll('+premium', '')} • ${profile.homeRegion}',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          const Text(
            'Looking for clean waves, easy travel days, and people to paddle out with.',
            style: TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ProfilePill(
                label: profile.premium ? 'Premium forecast' : 'Free explorer',
              ),
              const _ProfilePill(label: 'Surf travel'),
              const _ProfilePill(label: 'Open to paddle outs'),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}

class _ProfilePill extends StatelessWidget {
  const _ProfilePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: Text(label, style: const TextStyle(color: Colors.white)),
    );
  }
}

class _ProfileSettingsSheet extends StatelessWidget {
  const _ProfileSettingsSheet({
    required this.premium,
    required this.selectedLocale,
    required this.onLocaleChanged,
    required this.onManagePremium,
    required this.onLogout,
  });

  final bool premium;
  final Locale selectedLocale;
  final ValueChanged<Locale> onLocaleChanged;
  final VoidCallback onManagePremium;
  final VoidCallback onLogout;

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
              subtitle: const Text('Switch demo account'),
              onTap: onLogout,
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendCard extends StatelessWidget {
  const _FriendCard({required this.friend});

  final FriendProfileModel friend;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 116,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(radius: 22, child: Text(friend.avatarEmoji)),
              const SizedBox(height: 6),
              Text(
                friend.displayName,
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                friend.homeRegion,
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfilePostGrid extends StatelessWidget {
  const _ProfilePostGrid({required this.posts, required this.spots});

  final List<SocialPostModel> posts;
  final List<SpotModel> spots;

  @override
  Widget build(BuildContext context) {
    if (posts.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const Icon(Icons.grid_on_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Your photos, videos, and posts will show here in a clean grid.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: posts.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemBuilder: (context, index) {
        return _ProfilePostTile(post: posts[index], spots: spots);
      },
    );
  }
}

class _ProfilePostTile extends StatelessWidget {
  const _ProfilePostTile({required this.post, required this.spots});

  final SocialPostModel post;
  final List<SpotModel> spots;

  @override
  Widget build(BuildContext context) {
    final media = post.media.isEmpty ? null : post.media.first;
    final spotName = _spotNameForId(spots, post.spotId);

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (media != null && media.mediaType == 'photo')
            Image.network(
              media.thumbnailUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _TextPostPreview(post: post),
            )
          else if (media != null && media.mediaType == 'video')
            Container(
              color: const Color(0xFF143F3D),
              child: const Icon(
                Icons.play_circle_fill,
                color: Colors.white,
                size: 34,
              ),
            )
          else
            _TextPostPreview(post: post),
          if (spotName != null)
            Positioned(
              left: 6,
              right: 6,
              bottom: 6,
              child: Text(
                spotName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  shadows: [Shadow(blurRadius: 8)],
                ),
              ),
            ),
          if (media?.mediaType == 'video')
            const Positioned(
              right: 6,
              top: 6,
              child: Icon(Icons.videocam, color: Colors.white, size: 18),
            ),
        ],
      ),
    );
  }
}

class _TextPostPreview extends StatelessWidget {
  const _TextPostPreview({required this.post});

  final SocialPostModel post;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      color: const Color(0xFFE8E1D2),
      child: Align(
        alignment: Alignment.topLeft,
        child: Text(
          post.body.isEmpty ? 'Post' : post.body,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

String? _spotNameForId(List<SpotModel> spots, String? spotId) {
  if (spotId == null) return null;
  for (final spot in spots) {
    if (spot.id == spotId) return spot.name;
  }
  return null;
}
