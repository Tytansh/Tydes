import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../social/social_feed.dart';
import '../social/social_profile.dart';

final dashboardProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchDashboard(),
);
final meProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchMe(),
);
final homeAdsProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchAds(),
);
final feedFriendsProvider = FutureProvider((ref) {
  ref.watch(socialRefreshKeyProvider);
  return ref.watch(surfRepositoryProvider).fetchFriends();
});
final socialProfilesProvider = FutureProvider((ref) {
  ref.watch(socialRefreshKeyProvider);
  return ref.watch(surfRepositoryProvider).fetchSocialProfiles();
});

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  Future<void> _refreshFeed(WidgetRef ref) async {
    ref.invalidate(travelFeedPostsProvider);
    ref.invalidate(travelFeedSpotsProvider);
    await Future.wait([
      ref.read(travelFeedPostsProvider.future),
      ref.read(travelFeedSpotsProvider.future),
      ref.refresh(socialEngagementHydrationProvider.future),
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(meProvider);
    final spots = ref.watch(travelFeedSpotsProvider);
    final spotItems = spots.valueOrNull ?? const [];
    final sessionExpired = user.hasError && _isSessionExpiredError(user.error);

    ref.listen<AsyncValue<UserProfile>>(meProvider, (_, next) {
      if (!next.hasError || !_isSessionExpiredError(next.error)) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          context.go('/login');
        }
      });
    });

    if (user.isLoading || sessionExpired) {
      return _AuthGateLoadingPage(
        message: sessionExpired
            ? 'Taking you to sign in...'
            : 'Loading your profile...',
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: _FeedSearchPill(onTap: () => context.push('/people-search')),
        backgroundColor: Theme.of(context).colorScheme.surface,
        surfaceTintColor: Theme.of(context).colorScheme.surface,
        actions: [
          user.maybeWhen(
            data: (profile) => _ProfileHeaderChip(
              name: profile.displayName.split(' ').first,
              onTap: () => ref.read(currentTabProvider.notifier).state = 4,
            ),
            orElse: () => _ProfileHeaderChip(
              name: sessionExpired ? 'Sign in' : 'Profile',
              onTap: () => sessionExpired
                  ? context.go('/login')
                  : ref.read(currentTabProvider.notifier).state = 4,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              style: tydesPostButtonStyle(),
              onPressed: () => sessionExpired
                  ? context.go('/login')
                  : showCreatePostSheet(context, spotItems),
              child: const Text('Post'),
            ),
          ),
        ],
      ),
      body: RefreshIndicator.adaptive(
        onRefresh: () => _refreshFeed(ref),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          children: [const TravelFeedSection(showHeader: false)],
        ),
      ),
    );
  }
}

bool _isSessionExpiredError(Object? error) {
  return error.toString().toLowerCase().contains('session expired');
}

class _AuthGateLoadingPage extends StatelessWidget {
  const _AuthGateLoadingPage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 34,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(
                color: Color(0xFF5D686C),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileHeaderChip extends StatelessWidget {
  const _ProfileHeaderChip({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.person_outline_rounded,
                size: 17,
                color: scheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                name,
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeedSearchPill extends StatelessWidget {
  const _FeedSearchPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: 'Search surfers',
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: scheme.outline.withValues(alpha: 0.18)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(Icons.search_rounded, color: scheme.primary, size: 20),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Search surfers',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PeopleSearchPage extends ConsumerStatefulWidget {
  const PeopleSearchPage({super.key});

  @override
  ConsumerState<PeopleSearchPage> createState() => _PeopleSearchPageState();
}

class _PeopleSearchPageState extends ConsumerState<PeopleSearchPage> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final friends = ref.watch(feedFriendsProvider);
    final socialProfiles = ref.watch(socialProfilesProvider);
    final posts = ref.watch(travelFeedPostsProvider);
    final profiles = _searchProfiles(
      me: me.valueOrNull,
      friends: friends.valueOrNull ?? const [],
      socialProfiles: socialProfiles.valueOrNull ?? const [],
      posts: posts.valueOrNull ?? const [],
    );
    final results = _filterProfiles(profiles: profiles, query: _query);
    return Scaffold(
      appBar: AppBar(title: const Text('Find surfers')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              hintText: 'Search surfers',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _controller.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.close_rounded),
                    ),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Text(
                _query.trim().isEmpty ? 'Suggested people' : 'Results',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (friends.isLoading ||
              socialProfiles.isLoading ||
              posts.isLoading ||
              me.isLoading)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (results.isEmpty)
            const _NoSearchResultsCard()
          else
            ...results.map(
              (profile) => _UserSearchResultTile(
                profile: profile,
                currentUserId: me.valueOrNull?.id,
              ),
            ),
        ],
      ),
    );
  }
}

class _UserSearchResultTile extends ConsumerWidget {
  const _UserSearchResultTile({
    required this.profile,
    required this.currentUserId,
  });

  final PublicProfilePreview profile;
  final String? currentUserId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMe = profile.userId == currentUserId;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => _openSearchProfile(context, ref, profile),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: tydesAvatarBackground,
                backgroundImage: profile.avatarUrl == null
                    ? null
                    : NetworkImage(profile.avatarUrl!),
                child: profile.avatarUrl == null
                    ? Text(
                        _initialFor(profile.displayName),
                        style: const TextStyle(
                          color: tydesAvatarForeground,
                          fontWeight: FontWeight.w900,
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
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                        if (profile.premium) ...[
                          const SizedBox(width: 5),
                          const Icon(
                            Icons.verified_rounded,
                            color: Color(0xFF2AA7A1),
                            size: 16,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if ((profile.handle ?? '').isNotEmpty)
                          '@${profile.handle}',
                        if ((profile.location ?? '').isNotEmpty)
                          profile.location,
                      ].join(' • '),
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if ((profile.subtitle ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        profile.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (!isMe) FollowButton(userId: profile.userId, compact: true),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoSearchResultsCard extends StatelessWidget {
  const _NoSearchResultsCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Text(
          'No surfers found yet. Try a name like Lina or an @tag like @linareef.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

List<PublicProfilePreview> _searchProfiles({
  required UserProfile? me,
  required List<FriendProfileModel> friends,
  required List<SocialProfileModel> socialProfiles,
  required List<SocialPostModel> posts,
}) {
  final currentUserId = me?.id;
  final currentHandle = _profileHandleKey(
    PublicProfilePreview(
      userId: currentUserId ?? '',
      displayName: me?.displayName ?? '',
      handle: me?.handle,
    ),
  );
  final profiles = <String, _RankedSearchProfile>{};

  void addProfile(PublicProfilePreview profile, int priority) {
    final handleKey = _profileHandleKey(profile);
    if (profile.userId == currentUserId) return;
    if (profile.userId == 'usr_demo') return;
    if (handleKey != null && handleKey == currentHandle) return;

    final key = handleKey ?? 'id:${profile.userId}';
    final existing = profiles[key];
    if (existing == null ||
        _shouldReplaceSearchProfile(existing, profile, priority)) {
      profiles[key] = _RankedSearchProfile(profile, priority);
    }
  }

  for (final friend in friends) {
    addProfile(
      PublicProfilePreview(
        userId: friend.id,
        displayName: friend.displayName,
        handle: _handleFromName(friend.displayName),
        subtitle: friend.vibe,
        location: friend.homeRegion,
        surfSkill: 'beginner',
      ),
      10,
    );
  }

  for (final profile in socialProfiles) {
    addProfile(
      PublicProfilePreview(
        userId: profile.userId,
        displayName: profile.displayName,
        handle: profile.handle,
        avatarUrl: profile.avatarUrl,
        premium: profile.premium,
        subtitle: profile.subtitle,
        location: profile.location,
        surfSkill: profile.surfSkill ?? 'beginner',
      ),
      50,
    );
  }

  for (final post in posts) {
    addProfile(
      PublicProfilePreview(
        userId: post.userId,
        displayName: post.authorName,
        handle: post.authorHandle ?? _handleFromName(post.authorName),
        avatarUrl: post.authorAvatarUrl,
        premium: post.authorPremium,
        subtitle: 'Posted recently on Tydes',
        location: null,
        surfSkill: 'beginner',
      ),
      30,
    );
  }

  for (final profile in _extraSearchProfiles) {
    addProfile(profile, 5);
  }

  final list = profiles.values.map((item) => item.profile).toList();
  list.sort((a, b) => a.displayName.compareTo(b.displayName));
  return list;
}

class _RankedSearchProfile {
  const _RankedSearchProfile(this.profile, this.priority);

  final PublicProfilePreview profile;
  final int priority;
}

bool _shouldReplaceSearchProfile(
  _RankedSearchProfile existing,
  PublicProfilePreview candidate,
  int candidatePriority,
) {
  if (candidatePriority != existing.priority) {
    return candidatePriority > existing.priority;
  }
  final current = existing.profile;
  if (candidate.avatarUrl != null && current.avatarUrl == null) return true;
  if (candidate.premium && !current.premium) return true;
  if ((candidate.handle ?? '').isNotEmpty && (current.handle ?? '').isEmpty) {
    return true;
  }
  return false;
}

List<PublicProfilePreview> _filterProfiles({
  required List<PublicProfilePreview> profiles,
  required String query,
}) {
  final q = _normalizeSearchQuery(query);
  final results = profiles.where((profile) {
    if (q.isEmpty) return true;
    return _profileNameMatches(profile, q);
  }).toList();
  if (q.isNotEmpty) {
    results.sort((a, b) {
      final aHandle = _normalizeSearchQuery(a.handle ?? '');
      final bHandle = _normalizeSearchQuery(b.handle ?? '');
      final exactCompare = _boolRank(
        bHandle == q,
      ).compareTo(_boolRank(aHandle == q));
      if (exactCompare != 0) return exactCompare;
      final handleLengthCompare = aHandle.length.compareTo(bHandle.length);
      if (handleLengthCompare != 0) return handleLengthCompare;
      return a.displayName.compareTo(b.displayName);
    });
  }
  return results.take(q.isEmpty ? 12 : 30).toList();
}

int _boolRank(bool value) => value ? 1 : 0;

bool _profileNameMatches(PublicProfilePreview profile, String query) {
  final handle = _normalizeSearchQuery(profile.handle ?? '');
  if (handle.startsWith(query)) return true;

  final nameParts = profile.displayName
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((part) => part.isNotEmpty);
  return nameParts.any((part) => part.startsWith(query));
}

String _normalizeSearchQuery(String value) {
  return value.trim().toLowerCase().replaceFirst(RegExp(r'^@+'), '');
}

String? _profileHandleKey(PublicProfilePreview profile) {
  final handle = _normalizeSearchQuery(profile.handle ?? '');
  return handle.isEmpty ? null : handle;
}

void _openSearchProfile(
  BuildContext context,
  WidgetRef ref,
  PublicProfilePreview profile,
) {
  final currentUserId = ref.read(meProvider).valueOrNull?.id;
  if (profile.userId == currentUserId) {
    ref.read(currentTabProvider.notifier).state = 4;
    return;
  }
  context.push('/profile/${profile.userId}', extra: profile);
}

String? _handleFromName(String? name) {
  if (name == null || name.trim().isEmpty) return null;
  return name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

String _initialFor(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  return trimmed.characters.first.toUpperCase();
}

const _extraSearchProfiles = [
  PublicProfilePreview(
    userId: 'suggested_tara_sets',
    displayName: 'Tara Sets',
    handle: 'tarasets',
    subtitle: 'Followed by Ari Dawn and Lina Reef',
    location: 'Canggu',
  ),
  PublicProfilePreview(
    userId: 'suggested_reef_milo',
    displayName: 'Reef Milo',
    handle: 'reefmilo',
    subtitle: 'Followed by Jo Tide',
    location: 'Siargao',
  ),
  PublicProfilePreview(
    userId: 'suggested_ella_tide',
    displayName: 'Ella Tide',
    handle: 'ellatide',
    subtitle: 'Followed by Maya Surfer',
    location: 'Uluwatu',
  ),
];
