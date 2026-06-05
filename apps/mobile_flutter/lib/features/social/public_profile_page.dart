import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import 'social_feed.dart';
import 'social_profile.dart';

final _publicProfileBundleProvider = FutureProvider((ref) async {
  final repository = ref.watch(surfRepositoryProvider);
  final results = await Future.wait([
    repository.fetchMe(),
    repository.fetchFriends(),
    repository.fetchSocialPosts(),
    repository.fetchSpots(),
  ]);
  return _PublicProfileBundle(
    me: results[0] as UserProfile,
    friends: results[1] as List<FriendProfileModel>,
    posts: results[2] as List<SocialPostModel>,
    spots: results[3] as List<SpotModel>,
  );
});

class PublicProfilePage extends ConsumerWidget {
  const PublicProfilePage({
    super.key,
    required this.userId,
    this.initialPostId,
    this.seedProfile,
  });

  final String userId;
  final String? initialPostId;
  final PublicProfilePreview? seedProfile;

  Future<void> _refreshProfile(WidgetRef ref) async {
    ref.invalidate(_publicProfileBundleProvider);
    await Future.wait([
      ref.read(_publicProfileBundleProvider.future),
      ref.refresh(socialEngagementHydrationProvider.future),
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bundle = ref.watch(_publicProfileBundleProvider);
    ref.watch(socialEngagementHydrationProvider);
    final loadedData = bundle.valueOrNull;
    final headerProfile = loadedData == null
        ? seedProfile
        : _buildResolvedProfile(userId, seedProfile, loadedData);
    final headerIsMe = loadedData?.me.id == userId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          if (headerProfile != null && headerIsMe != true)
            IconButton(
              onPressed: () =>
                  _openProfileDirectMessage(context, headerProfile),
              icon: const Icon(Icons.send_rounded),
              tooltip: 'Message',
            ),
        ],
      ),
      body: RefreshIndicator.adaptive(
        onRefresh: () => _refreshProfile(ref),
        child: bundle.when(
          data: (data) {
            final profile = _buildResolvedProfile(userId, seedProfile, data);
            final userPosts = data.posts
                .where((post) => post.userId == userId)
                .toList();
            if (initialPostId != null) {
              userPosts.sort((a, b) {
                if (a.id == initialPostId) return -1;
                if (b.id == initialPostId) return 1;
                return 0;
              });
            }
            final isMe = data.me.id == userId;
            final followedIds = ref.watch(followedUserIdsProvider);
            final followerIds = ref.watch(followerUserIdsProvider);
            final profileReposts = repostedItemsForProfile(
              posts: data.posts,
              profileUserId: userId,
              currentUserId: data.me.id,
              myRepostedPostIds: ref.watch(visibleRepostedPostIdsProvider),
              myRepostActivityTimes: ref.watch(
                visibleRepostActivityTimesProvider,
              ),
            );
            final profileItems = [
              for (final item in profileReposts)
                _PublicProfileFeedItem.repost(item),
              for (final post in userPosts) _PublicProfileFeedItem.post(post),
            ]..sort((a, b) => b.activityAt.compareTo(a.activityAt));
            final friends = _profileFriends(profile, data);
            final followers = _profileFollowers(
              profile,
              data,
              followedIds.contains(profile.userId),
              isMe ? followerIds : const {},
            );

            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(20),
              children: [
                _PublicProfileHero(
                  profile: profile,
                  postsCount: userPosts.length + profileReposts.length,
                  friends: friends,
                  followers: followers,
                  isMe: isMe,
                  onPersonTap: (person) => _openProfileFromPublicPage(
                    context,
                    ref,
                    person,
                    data.me.id,
                  ),
                ),
                const SizedBox(height: 18),
                if (!isMe) FollowButton(userId: profile.userId, expanded: true),
                const SizedBox(height: 22),
                Text('Posts', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                if (userPosts.isEmpty && profileReposts.isEmpty)
                  const _EmptyProfilePosts()
                else ...[
                  for (final item in profileItems) ...[
                    KeyedSubtree(
                      key: ValueKey(item.key),
                      child: _PublicProfilePostCard(
                        profile: item.repostHeader == null
                            ? profile
                            : _profileFromPost(item.post),
                        post: item.post,
                        spot: _spotForId(data.spots, item.post.spotId),
                        isMe: item.repostHeader == null
                            ? isMe
                            : data.me.id == item.post.userId,
                        repostHeader: item.repostHeader,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ],
            );
          },
          loading: () => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(20),
            children: const [
              SizedBox(
                height: 280,
                child: Center(child: CircularProgressIndicator()),
              ),
            ],
          ),
          error: (error, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(20),
            children: [Text('Could not load profile: $error')],
          ),
        ),
      ),
    );
  }
}

class _PublicProfileFeedItem {
  const _PublicProfileFeedItem({
    required this.post,
    required this.activityAt,
    required this.key,
    this.repostHeader,
  });

  factory _PublicProfileFeedItem.post(SocialPostModel post) =>
      _PublicProfileFeedItem(
        post: post,
        activityAt: _publicProfilePostCreatedAt(post),
        key: 'public_profile_post_${post.id}',
      );

  factory _PublicProfileFeedItem.repost(RepostedPostItem item) =>
      _PublicProfileFeedItem(
        post: item.post,
        activityAt: item.activityAt,
        key: 'public_profile_repost_${item.header}_${item.post.id}',
        repostHeader: item.header,
      );

  final SocialPostModel post;
  final DateTime activityAt;
  final String key;
  final String? repostHeader;
}

DateTime _publicProfilePostCreatedAt(SocialPostModel post) {
  return DateTime.tryParse(post.createdAt) ??
      DateTime.fromMillisecondsSinceEpoch(0);
}

class _PublicProfileHero extends StatelessWidget {
  const _PublicProfileHero({
    required this.profile,
    required this.postsCount,
    required this.friends,
    required this.followers,
    required this.isMe,
    required this.onPersonTap,
  });

  final PublicProfilePreview profile;
  final int postsCount;
  final List<ProfilePerson> friends;
  final List<ProfilePerson> followers;
  final bool isMe;
  final ValueChanged<PublicProfilePreview> onPersonTap;

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
                  backgroundColor: tydesAvatarBackground,
                  backgroundImage: profile.avatarUrl == null
                      ? null
                      : NetworkImage(profile.avatarUrl!),
                  child: profile.avatarUrl == null
                      ? Text(
                          tydesProfileInitial(profile.displayName),
                          style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                            color: tydesAvatarForeground,
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _ProfileStat(value: postsCount.toString(), label: 'Posts'),
                    _ProfileStat(
                      value: friends.length.toString(),
                      label: 'Following',
                      onTap: () => showProfilePeopleSheet(
                        context: context,
                        title: 'Following',
                        people: friends,
                        onProfileTap: onPersonTap,
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
                        onProfileTap: onPersonTap,
                        emptyText: 'No followers yet.',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Flexible(
                child: Text(
                  profile.displayName,
                  style: Theme.of(
                    context,
                  ).textTheme.headlineMedium?.copyWith(color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (profile.premium) ...[
                const SizedBox(width: 8),
                const Icon(Icons.verified_rounded, color: Color(0xFF8DE7DF)),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            [
              if (profile.handle != null && profile.handle!.isNotEmpty)
                '@${profile.handle}',
              profile.location ?? 'Bali',
              _skillLabel(profile.surfSkill),
            ].join(' • '),
            style: const TextStyle(color: Colors.white70),
          ),
          if (profile.subtitle != null && profile.subtitle!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              profile.subtitle!,
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ],
      ),
    );
  }
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

String _skillLabel(String skill) {
  switch (skill) {
    case 'pro':
      return 'Pro';
    case 'intermediate':
      return 'Skilled';
    default:
      return 'Beginner';
  }
}

class _PublicProfilePostCard extends StatelessWidget {
  const _PublicProfilePostCard({
    required this.profile,
    required this.post,
    required this.spot,
    required this.isMe,
    this.repostHeader,
  });

  final PublicProfilePreview profile;
  final SocialPostModel post;
  final SpotModel? spot;
  final bool isMe;
  final String? repostHeader;

  @override
  Widget build(BuildContext context) {
    final isEvent = _isEventPost(post.postType);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (repostHeader != null) ...[
              _PublicRepostHeader(label: repostHeader!),
              const SizedBox(height: 10),
            ],
            Row(
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
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
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
                      Text(
                        profile.handle == null || profile.handle!.isEmpty
                            ? '${post.visibility == 'followers' ? 'Followers' : 'Public'} ${isEvent ? 'event' : 'post'}'
                            : '@${profile.handle} • ${post.visibility == 'followers' ? 'Followers' : 'Public'} ${isEvent ? 'event' : 'post'}',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (spot != null) ...[
              const SizedBox(height: 10),
              ActionChip(
                avatar: const Icon(Icons.place_outlined, size: 16),
                label: Text(spot!.name),
                onPressed: () => context.push('/spot/${spot!.id}'),
              ),
            ],
            const SizedBox(height: 12),
            if (post.media.isNotEmpty) ...[
              SocialPostMediaCarousel(media: post.media),
              const SizedBox(height: 12),
            ],
            if (post.body.isNotEmpty) SocialPostBodyPreview(body: post.body),
            if (isEvent) ...[
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

class _PublicRepostHeader extends StatelessWidget {
  const _PublicRepostHeader({required this.label});

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

class _EmptyProfilePosts extends StatelessWidget {
  const _EmptyProfilePosts();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Text(
          'No posts yet.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _PublicProfileBundle {
  const _PublicProfileBundle({
    required this.me,
    required this.friends,
    required this.posts,
    required this.spots,
  });

  final UserProfile me;
  final List<FriendProfileModel> friends;
  final List<SocialPostModel> posts;
  final List<SpotModel> spots;
}

PublicProfilePreview _buildResolvedProfile(
  String userId,
  PublicProfilePreview? seed,
  _PublicProfileBundle data,
) {
  if (data.me.id == userId) {
    return PublicProfilePreview(
      userId: data.me.id,
      displayName: data.me.displayName,
      handle: data.me.handle,
      avatarUrl: data.me.avatarUrl,
      premium: data.me.premium,
      subtitle: data.me.bio,
      location: data.me.homeRegion,
      surfSkill: data.me.surfSkill,
    );
  }

  final friend = _friendForId(data.friends, userId);
  final post = _firstPostForUser(data.posts, userId);
  return PublicProfilePreview(
    userId: userId,
    displayName:
        seed?.displayName ??
        friend?.displayName ??
        post?.authorName ??
        'Surfer',
    handle:
        seed?.handle ??
        post?.authorHandle ??
        _handleFromName(friend?.displayName),
    avatarUrl: seed?.avatarUrl ?? post?.authorAvatarUrl,
    premium: seed?.premium ?? post?.authorPremium ?? false,
    subtitle: friend?.vibe ?? seed?.subtitle ?? 'Surf traveler on Tydes.',
    location: friend?.homeRegion ?? seed?.location ?? 'Bali',
    surfSkill: seed?.surfSkill ?? 'beginner',
  );
}

FriendProfileModel? _friendForId(List<FriendProfileModel> friends, String id) {
  for (final friend in friends) {
    if (friend.id == id) return friend;
  }
  return null;
}

SocialPostModel? _firstPostForUser(List<SocialPostModel> posts, String id) {
  for (final post in posts) {
    if (post.userId == id) return post;
  }
  return null;
}

SpotModel? _spotForId(List<SpotModel> spots, String? id) {
  if (id == null) return null;
  for (final spot in spots) {
    if (spot.id == id) return spot;
  }
  return null;
}

String? _handleFromName(String? name) {
  if (name == null || name.trim().isEmpty) return null;
  return name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

String _displayNameFromUserId(String userId) {
  final cleaned = userId
      .replaceFirst(RegExp(r'^(usr|friend|sample|follower)_'), '')
      .replaceAll(RegExp(r'[^a-z0-9]+', caseSensitive: false), ' ')
      .trim();
  if (cleaned.isEmpty) return 'Tydes Surfer';
  return cleaned
      .split(RegExp(r'\s+'))
      .map(
        (word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1)}',
      )
      .join(' ');
}

bool _isEventPost(String postType) {
  return postType == 'surf_plan' || postType == 'looking_for_buddy';
}

PublicProfilePreview _profileFromPost(SocialPostModel post) {
  return PublicProfilePreview(
    userId: post.userId,
    displayName: post.authorName,
    handle: post.authorHandle,
    avatarUrl: post.authorAvatarUrl,
    premium: post.authorPremium,
    subtitle: 'Surf traveler on Tydes',
  );
}

void _openProfileDirectMessage(
  BuildContext context,
  PublicProfilePreview profile,
) {
  final threadId = (profile.handle?.trim().isNotEmpty ?? false)
      ? profile.handle!.trim()
      : profile.userId;
  context.push('/messages?thread=$threadId', extra: profile);
}

List<ProfilePerson> _profileFriends(
  PublicProfilePreview profile,
  _PublicProfileBundle data,
) {
  final people = <ProfilePerson>[];
  for (final friend in data.friends) {
    if (friend.id == profile.userId) continue;
    people.add(
      ProfilePerson(
        profile: _previewFromFriend(friend),
        subtitle: friend.homeRegion,
        canFollow: friend.id != data.me.id,
      ),
    );
  }
  if (profile.userId != data.me.id) {
    people.insert(
      0,
      ProfilePerson(
        profile: PublicProfilePreview(
          userId: data.me.id,
          displayName: data.me.displayName,
          handle: data.me.handle,
          avatarUrl: data.me.avatarUrl,
          premium: data.me.premium,
          subtitle: data.me.bio,
        ),
        subtitle: 'Mutual friend',
        canFollow: false,
      ),
    );
  }
  return people;
}

List<ProfilePerson> _profileFollowers(
  PublicProfilePreview profile,
  _PublicProfileBundle data,
  bool followedByViewer,
  Set<String> followerUserIds,
) {
  final followers = <ProfilePerson>[..._sampleFollowers(profile)];
  if (followedByViewer && profile.userId != data.me.id) {
    followers.insert(
      0,
      ProfilePerson(
        profile: PublicProfilePreview(
          userId: data.me.id,
          displayName: data.me.displayName,
          handle: data.me.handle,
          avatarUrl: data.me.avatarUrl,
          premium: data.me.premium,
          subtitle: data.me.bio,
        ),
        subtitle: 'Following',
        canFollow: false,
      ),
    );
  }
  if (profile.userId == data.me.id) {
    final existingIds = followers
        .map((person) => person.profile.userId)
        .toSet();
    for (final userId in followerUserIds) {
      if (existingIds.contains(userId)) continue;
      followers.add(
        ProfilePerson(
          profile: _profileForUserId(userId, data),
          subtitle: 'Follower',
          forceFollowerActions: true,
        ),
      );
    }
  }
  return followers;
}

List<ProfilePerson> _sampleFollowers(PublicProfilePreview profile) {
  final seed = profile.userId.codeUnits.fold<int>(0, (sum, item) => sum + item);
  final count = profile.userId == 'friend_ari' ? 18 : 14 + seed % 9;
  final names = [
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
    'Taj Current',
    'Ivy Reef',
    'Oli Barrels',
    'Zara Lineup',
    'Leo Lagoon',
    'Mina Shorey',
    'Theo Trim',
    'Ava Walled',
    'Rio Banks',
  ];
  return names.take(count).map((name) {
    return ProfilePerson(
      profile: PublicProfilePreview(
        userId:
            'sample_${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}',
        displayName: name,
        handle: _handleFromName(name),
        subtitle: 'Surf traveler on Tydes',
      ),
      subtitle: 'Follower',
    );
  }).toList();
}

PublicProfilePreview _profileForUserId(
  String userId,
  _PublicProfileBundle data,
) {
  if (userId == data.me.id) {
    return PublicProfilePreview(
      userId: data.me.id,
      displayName: data.me.displayName,
      handle: data.me.handle,
      avatarUrl: data.me.avatarUrl,
      premium: data.me.premium,
      subtitle: data.me.bio,
      location: data.me.homeRegion,
      surfSkill: data.me.surfSkill,
    );
  }
  final friend = _friendForId(data.friends, userId);
  if (friend != null) return _previewFromFriend(friend);
  return PublicProfilePreview(
    userId: userId,
    displayName: _displayNameFromUserId(userId),
    handle: _handleFromName(userId),
    subtitle: 'Surf traveler on Tydes',
  );
}

PublicProfilePreview _previewFromFriend(FriendProfileModel friend) {
  return PublicProfilePreview(
    userId: friend.id,
    displayName: friend.displayName,
    handle: _handleFromName(friend.displayName),
    subtitle: friend.vibe,
  );
}

void _openProfileFromPublicPage(
  BuildContext context,
  WidgetRef ref,
  PublicProfilePreview profile,
  String currentUserId,
) {
  if (profile.userId == currentUserId) {
    ref.read(currentTabProvider.notifier).state = 4;
    context.go('/');
    return;
  }
  context.push('/profile/${profile.userId}', extra: profile);
}
