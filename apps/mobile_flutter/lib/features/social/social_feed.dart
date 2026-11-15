import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderViewport, RenderShrinkWrappingViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../app/router.dart';
import '../../core/media/native_hls_support.dart';
import '../../core/media/video_playback_sources.dart';
import '../../core/moderation/content_moderation.dart';
import '../../core/network/api_error_message.dart';
import '../../core/network/api_models.dart';
import '../../core/network/spot_catalog_provider.dart';
import '../../core/network/surf_repository.dart';
import '../../core/widgets/media_image_strategy.dart';
import 'direct_messages_page.dart';
import 'event_chat_page.dart';
import 'post_media_zoom.dart';
import 'post_composer_feature_page.dart';
import 'post_composer_shared.dart';
export 'post_composer_shared.dart'
    show socialPostMediaCarouselPhysics, socialPostMediaCarouselShowsArrows;
import 'social_profile.dart';
import 'feed_pagination.dart';
export 'feed_pagination.dart'
    show feedPaginationProvider, FeedPaginationController, FeedPaginationState;
import '../auth/auth_return_path.dart';
import '../home/home_page.dart' show meProvider;
import '../public_previews/public_link_button.dart';

final travelFeedPostsProvider = FutureProvider<List<SocialPostModel>>((
  ref,
) async {
  ref.watch(socialRefreshKeyProvider);
  final pagination = ref.watch(feedPaginationProvider.notifier);
  return AccountScopedFeedPosts(
    accountId: pagination.accountId,
    posts: await pagination.refreshInitial(),
  );
});
final travelFeedSpotsProvider = spotCatalogProvider;
final currentViewerProvider = FutureProvider<UserProfile>(
  (ref) => ref.watch(meProvider.future),
);
final videoSoundEnabledProvider = StateProvider<bool>((ref) => false);
final surfInviteRsvpProvider = StateProvider<Set<String>>((ref) => {});
final likedPostIdsProvider = StateProvider<Set<String>>((ref) => {});
final repostedPostIdsProvider = StateProvider<List<String>>((ref) => []);
final repostActivityTimesProvider = StateProvider<Map<String, DateTime>>(
  (ref) => {},
);
// Feed/profile rows refresh on pull-to-refresh so reposting does not yank the
// current scroll position while someone is reading.
final visibleRepostedPostIdsProvider = StateProvider<List<String>>((ref) => []);
final visibleRepostActivityTimesProvider = StateProvider<Map<String, DateTime>>(
  (ref) => {},
);
final likedCommentIdsProvider = StateProvider<Set<String>>((ref) => {});
const _commentLikeAccent = Color(0xFF2AA7A1);
final postCommentsProvider = StateProvider<Map<String, List<SocialComment>>>(
  (ref) => demoPostComments,
);
final socialEngagementHydrationProvider = FutureProvider<void>((ref) async {
  final engagement = await ref
      .watch(surfRepositoryProvider)
      .fetchSocialEngagement();
  _applySocialEngagement(ref, engagement);
});

class SocialComment {
  const SocialComment({
    required this.id,
    required this.postId,
    required this.userId,
    required this.authorName,
    required this.text,
    this.authorHandle,
    this.authorAvatarUrl,
    this.authorInitial,
    this.authorPremium = false,
    this.replyToCommentId,
    this.isMe = false,
  });

  final String id;
  final String postId;
  final String userId;
  final String authorName;
  final String text;
  final String? authorHandle;
  final String? authorAvatarUrl;
  final String? authorInitial;
  final bool authorPremium;
  final String? replyToCommentId;
  final bool isMe;

  factory SocialComment.fromModel(SocialCommentModel model) => SocialComment(
    id: model.id,
    postId: model.postId,
    userId: model.userId,
    authorName: model.authorName,
    authorHandle: model.authorHandle,
    authorAvatarUrl: model.authorAvatarUrl,
    authorPremium: model.authorPremium,
    authorInitial: model.authorName.trim().isEmpty
        ? '?'
        : model.authorName.characters.first.toUpperCase(),
    text: model.text,
    replyToCommentId: model.replyToCommentId,
    isMe: model.userId == 'usr_demo',
  );
}

void _applySocialEngagement(
  dynamic ref,
  SocialEngagementModel engagement, {
  bool syncVisibleReposts = true,
}) {
  final repostActivityTimes = {
    for (final repost in engagement.reposts)
      repost.postId: DateTime.tryParse(repost.createdAt) ?? DateTime.now(),
  };
  ref.read(likedPostIdsProvider.notifier).state = engagement.likedPostIds;
  ref.read(repostedPostIdsProvider.notifier).state = engagement.repostedPostIds;
  ref.read(repostActivityTimesProvider.notifier).state = repostActivityTimes;
  if (syncVisibleReposts) {
    if (!listEquals(
      ref.read(visibleRepostedPostIdsProvider),
      engagement.repostedPostIds,
    )) {
      ref.read(visibleRepostedPostIdsProvider.notifier).state =
          engagement.repostedPostIds;
    }
    if (!mapEquals(
      ref.read(visibleRepostActivityTimesProvider),
      repostActivityTimes,
    )) {
      ref.read(visibleRepostActivityTimesProvider.notifier).state =
          repostActivityTimes;
    }
  }
  ref.read(likedCommentIdsProvider.notifier).state = engagement.likedCommentIds;
  ref.read(surfInviteRsvpProvider.notifier).state = engagement.rsvpPostIds;
  ref.read(postCommentsProvider.notifier).state = _commentsByPost(
    engagement.comments.map(SocialComment.fromModel),
  );
}

Map<String, List<SocialComment>> _commentsByPost(
  Iterable<SocialComment> comments,
) {
  final grouped = <String, List<SocialComment>>{};
  for (final comment in comments) {
    grouped.putIfAbsent(comment.postId, () => []).add(comment);
  }
  return grouped;
}

const demoPostComments = <String, List<SocialComment>>{};

class RepostActivity {
  const RepostActivity({
    required this.postId,
    required this.userId,
    required this.displayName,
    required this.hoursAgo,
  });

  final String postId;
  final String userId;
  final String displayName;
  final int hoursAgo;
}

class RepostedPostItem {
  const RepostedPostItem({
    required this.post,
    required this.header,
    required this.activityAt,
  });

  final SocialPostModel post;
  final String header;
  final DateTime activityAt;
}

const demoRepostActivities = <RepostActivity>[];

List<RepostedPostItem> repostedItemsForFeed(
  List<SocialPostModel> posts,
  List<String> myRepostedPostIds,
  Map<String, DateTime> myRepostActivityTimes,
) {
  return [
    for (final postId in myRepostedPostIds)
      if (_postById(posts, postId) != null)
        RepostedPostItem(
          post: _postById(posts, postId)!,
          header: 'You reposted',
          activityAt:
              myRepostActivityTimes[postId] ??
              _postCreatedAt(_postById(posts, postId)!),
        ),
    for (final activity in demoRepostActivities)
      if (_postById(posts, activity.postId) != null)
        RepostedPostItem(
          post: _postById(posts, activity.postId)!,
          header: '${activity.displayName} reposted',
          activityAt: DateTime.now().subtract(
            Duration(hours: activity.hoursAgo),
          ),
        ),
  ];
}

List<RepostedPostItem> repostedItemsForProfile({
  required List<SocialPostModel> posts,
  required String profileUserId,
  required String currentUserId,
  required List<String> myRepostedPostIds,
  Map<String, DateTime> myRepostActivityTimes = const {},
}) {
  if (profileUserId == currentUserId) {
    return [
      for (final postId in myRepostedPostIds)
        if (_postById(posts, postId) != null)
          RepostedPostItem(
            post: _postById(posts, postId)!,
            header: 'You reposted',
            activityAt:
                myRepostActivityTimes[postId] ??
                _postCreatedAt(_postById(posts, postId)!),
          ),
    ];
  }
  return [
    for (final activity in demoRepostActivities)
      if (activity.userId == profileUserId &&
          _postById(posts, activity.postId) != null)
        RepostedPostItem(
          post: _postById(posts, activity.postId)!,
          header: '${activity.displayName} reposted',
          activityAt: DateTime.now().subtract(
            Duration(hours: activity.hoursAgo),
          ),
        ),
  ];
}

SocialPostModel? _postById(List<SocialPostModel> posts, String postId) {
  for (final post in posts) {
    if (post.id == postId) return post;
  }
  return null;
}

DateTime _postCreatedAt(SocialPostModel post) {
  return DateTime.tryParse(post.createdAt) ??
      DateTime.fromMillisecondsSinceEpoch(0);
}

ButtonStyle tydesPostButtonStyle() {
  return FilledButton.styleFrom(
    backgroundColor: const Color(0xFF079CA3),
    foregroundColor: Colors.white,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
  );
}

class TravelFeedSection extends ConsumerWidget {
  const TravelFeedSection({
    super.key,
    this.compact = false,
    this.showHeader = true,
    this.asSliver = false,
  });

  final bool compact;
  final bool showHeader;
  final bool asSliver;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final posts = ref.watch(travelFeedPostsProvider);
    // Paging status belongs to the footer. Keep already mounted post/media
    // widgets untouched while a later page loads, fails, or is retried.
    final pagination = ref.watch(
      feedPaginationProvider.select(
        (state) => (entries: state.entries, initialized: state.initialized),
      ),
    );
    final spots = ref.watch(travelFeedSpotsProvider);
    final spotItems = spots.valueOrNull ?? const <SpotModel>[];
    if (compact) ref.watch(socialEngagementHydrationProvider);
    ref.watch(socialRelationshipHydrationProvider);
    final blockedUserIds = ref.watch(blockedUserIdsProvider);

    Widget box(Widget child) =>
        asSliver ? SliverToBoxAdapter(child: child) : child;

    final previousPosts = posts.valueOrNull;
    final belongsToPreviousAccount =
        previousPosts is AccountScopedFeedPosts &&
        previousPosts.accountId !=
            ref.watch(feedPaginationProvider.notifier).accountId;
    final displayedPosts = belongsToPreviousAccount && !posts.hasError
        ? const AsyncLoading<List<SocialPostModel>>()
        : !compact && pagination.initialized
        ? AsyncData<List<SocialPostModel>>([
            for (final entry in pagination.entries) entry.post,
          ])
        : posts;
    final content = displayedPosts.when(
      skipLoadingOnReload: true,
      data: (items) {
        final visiblePosts = items
            .where((post) => !blockedUserIds.contains(post.userId))
            .toList();
        if (visiblePosts.isEmpty) return box(const _EmptyFeedCard());
        final repostedItems = compact || pagination.initialized
            ? const <RepostedPostItem>[]
            : repostedItemsForFeed(
                visiblePosts,
                ref.watch(visibleRepostedPostIdsProvider),
                ref.watch(visibleRepostActivityTimesProvider),
              );
        final feedItems = !compact && pagination.initialized
            ? [
                for (final entry in pagination.entries)
                  if (!blockedUserIds.contains(entry.post.userId))
                    _FeedPostItem(
                      entryId: entry.entryId,
                      post: entry.post,
                      activityAt: entry.activityAt,
                      repostHeader: entry.isRepost ? 'You reposted' : null,
                    ),
              ]
            : ([
                for (final item in repostedItems)
                  _FeedPostItem(
                    post: item.post,
                    repostHeader: item.header,
                    activityAt: item.activityAt,
                  ),
                for (final post in visiblePosts)
                  _FeedPostItem(post: post, activityAt: _postCreatedAt(post)),
              ]..sort((a, b) => b.activityAt.compareTo(a.activityAt)));
        final shown = compact ? feedItems.take(4).toList() : feedItems;
        String rowId(_FeedPostItem item) =>
            item.entryId ?? '${item.repostHeader ?? 'post'}_${item.post.id}';
        Widget row(int index) {
          final item = shown[index];
          return Padding(
            key: ValueKey(rowId(item)),
            padding: const EdgeInsets.only(bottom: 14),
            child: TydesDesktopPostWidth(
              child: _PostCard(
                post: item.post,
                spots: spotItems,
                repostHeader: item.repostHeader,
              ),
            ),
          );
        }

        if (asSliver) {
          final indexes = {
            for (var i = 0; i < shown.length; i++) rowId(shown[i]): i,
          };
          return SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, index) => row(index),
              childCount: shown.length,
              findChildIndexCallback: (key) =>
                  key is ValueKey<String> ? indexes[key.value] : null,
            ),
          );
        }
        return Column(
          children: [for (var i = 0; i < shown.length; i++) row(i)],
        );
      },
      loading: () => box(
        const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          ),
        ),
      ),
      error: (error, _) =>
          box(Text(friendlyLoadErrorMessage(error, label: 'posts'))),
    );
    final pagedContent = compact
        ? content
        : asSliver
        ? SliverMainAxisGroup(
            slivers: [
              content,
              const SliverToBoxAdapter(child: FeedPaginationFooter()),
            ],
          )
        : Column(children: [content, const FeedPaginationFooter()]);
    if (!showHeader) return pagedContent;
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Travel feed',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            FilledButton.icon(
              style: tydesPostButtonStyle(),
              onPressed: () => showCreatePostSheet(context, spotItems),
              icon: const Icon(Icons.add),
              label: const Text('Post'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Share clips, photos, plans, and surf travel updates.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 14),
      ],
    );
    return asSliver
        ? SliverMainAxisGroup(slivers: [box(header), pagedContent])
        : Column(children: [header, pagedContent]);
  }
}

class FeedPaginationFooter extends ConsumerWidget {
  const FeedPaginationFooter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pagination = ref.watch(feedPaginationProvider);
    if (pagination.error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(
          children: [
            Text(
              pagination.refreshFailed && pagination.entries.isNotEmpty
                  ? 'Could not refresh posts. Your loaded posts are still here.'
                  : pagination.initialized
                  ? 'Could not load more posts. Please try again.'
                  : 'Could not load posts. Please try again.',
              textAlign: TextAlign.center,
            ),
            TextButton.icon(
              onPressed: () =>
                  unawaited(ref.read(feedPaginationProvider.notifier).retry()),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry posts'),
            ),
          ],
        ),
      );
    }
    if (!pagination.initialized) return const SizedBox.shrink();
    if (pagination.isLoadingMore || pagination.isLoadingInitial) {
      return const Padding(
        padding: EdgeInsets.all(18),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (pagination.nextCursor == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: TextButton(
          onPressed: () =>
              unawaited(ref.read(feedPaginationProvider.notifier).loadMore()),
          child: const Text('Load more posts'),
        ),
      ),
    );
  }
}

class TydesDesktopPostWidth extends StatelessWidget {
  const TydesDesktopPostWidth({super.key, required this.child});

  static const maxWidth = 680.0;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Preserve phone proportions without growing taller than the desktop media.
class SocialPostMediaFrame extends StatelessWidget {
  const SocialPostMediaFrame({super.key, required this.child});

  // A 680px post has 4px card margins and 18px content padding on each side.
  static const maxHeight = TydesDesktopPostWidth.maxWidth - 44;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 980;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = (width / (desktop ? 1 : 4 / 5)).clamp(0.0, maxHeight);
        return SizedBox(width: width, height: height, child: child);
      },
    );
  }
}

class _FeedPostItem {
  const _FeedPostItem({
    required this.post,
    required this.activityAt,
    this.repostHeader,
    this.entryId,
  });

  final SocialPostModel post;
  final DateTime activityAt;
  final String? repostHeader;
  final String? entryId;
}

enum _PostSafetyAction { report, block }

enum _OwnPostAction { delete }

class _RepostHeader extends StatelessWidget {
  const _RepostHeader({required this.label});

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

Future<void> showCreatePostSheet(BuildContext context, List<SpotModel> spots) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (context) => PostComposerFeaturePage(spots: spots),
    ),
  );
}

class _EmptyFeedCard extends StatelessWidget {
  const _EmptyFeedCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const Icon(Icons.forum_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'No posts yet. Start the feed with a surf photo or trip note.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PostCard extends ConsumerWidget {
  const _PostCard({required this.post, required this.spots, this.repostHeader});

  final SocialPostModel post;
  final List<SpotModel> spots;
  final String? repostHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spot = postSpotForId(spots, post.spotId);
    final isSurfInvite = _isSurfInvite(post);
    final currentViewer = ref.watch(currentViewerProvider).valueOrNull;
    final isOwnPost = currentViewer != null && currentViewer.id == post.userId;
    final authorName = isOwnPost ? currentViewer.displayName : post.authorName;
    final authorAvatarUrl = isOwnPost
        ? currentViewer.avatarUrl
        : post.authorAvatarUrl;
    final authorHandle = isOwnPost ? currentViewer.handle : post.authorHandle;
    final authorPremium =
        post.authorPremium || (isOwnPost ? currentViewer.premium : false);
    final authorProfile = PublicProfilePreview(
      userId: post.userId,
      displayName: authorName,
      handle: authorHandle,
      avatarUrl: authorAvatarUrl,
      premium: authorPremium,
      subtitle: isOwnPost ? currentViewer.bio : 'Surf traveler on TYDES',
      location: isOwnPost ? currentViewer.homeRegion : null,
      surfSkill: isOwnPost ? currentViewer.surfSkill : 'beginner',
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: repostHeader == null
            ? null
            : () => context.push('/post/${post.id}'),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (repostHeader != null) ...[
                _RepostHeader(label: repostHeader!),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _openProfileTarget(
                      context: context,
                      ref: ref,
                      profile: authorProfile,
                      isMe: isOwnPost,
                    ),
                    child: TydesProfileAvatar(
                      size: 40,
                      displayName: authorName,
                      imageUrl: authorAvatarUrl,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _openProfileTarget(
                        context: context,
                        ref: ref,
                        profile: authorProfile,
                        isMe: isOwnPost,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
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
                              authorHandle == null || authorHandle.isEmpty
                                  ? '${_labelForVisibility(post.visibility)} ${_postKindLabel(post)}'
                                  : '@$authorHandle • ${_labelForVisibility(post.visibility)} ${_postKindLabel(post)}',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (isOwnPost) ...[
                    SharePostButton(post: post, spot: spot),
                    const SizedBox(width: 4),
                    OwnPostMenu(post: post),
                  ] else ...[
                    FollowButton(userId: post.userId, compact: true),
                    const SizedBox(width: 4),
                    _PostSafetyMenu(post: post),
                  ],
                ],
              ),
              if (spot != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.place_outlined, size: 16),
                      label: Text(spot.name),
                      onPressed: () => context.push('/spot/${spot.id}'),
                    ),
                    const Spacer(),
                    if (!isOwnPost) SharePostButton(post: post, spot: spot),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              if (post.media.isNotEmpty) ...[
                SocialPostMediaCarousel(media: post.media),
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
      ),
    );
  }
}

class _PostSafetyMenu extends ConsumerWidget {
  const _PostSafetyMenu({required this.post});

  final SocialPostModel post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_PostSafetyAction>(
      tooltip: 'Post options',
      icon: const Icon(Icons.more_horiz_rounded),
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _PostSafetyAction.report,
          child: Text('Report post'),
        ),
        PopupMenuItem(
          value: _PostSafetyAction.block,
          child: Text('Block surfer'),
        ),
      ],
      onSelected: (action) {
        switch (action) {
          case _PostSafetyAction.report:
            unawaited(_reportPost(context, ref, post));
          case _PostSafetyAction.block:
            unawaited(_confirmAndBlockPostAuthor(context, ref, post));
        }
      },
    );
  }
}

class OwnPostMenu extends ConsumerWidget {
  const OwnPostMenu({super.key, required this.post});

  final SocialPostModel post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_OwnPostAction>(
      tooltip: 'Post options',
      icon: const Icon(Icons.more_horiz_rounded),
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _OwnPostAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded),
              SizedBox(width: 10),
              Text('Delete post'),
            ],
          ),
        ),
      ],
      onSelected: (action) {
        if (action == _OwnPostAction.delete) {
          unawaited(_confirmAndDeletePost(context, ref, post));
        }
      },
    );
  }
}

Future<void> _confirmAndDeletePost(
  BuildContext context,
  WidgetRef ref,
  SocialPostModel post,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete this post?'),
      content: const Text(
        'The post and its uploaded photos or videos will be permanently deleted.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await ref.read(surfRepositoryProvider).deleteSocialPost(post.id);
    ref.read(socialRefreshKeyProvider.notifier).state++;
    ref.invalidate(travelFeedPostsProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Post deleted.')));
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not delete this post right now.')),
    );
  }
}

Future<void> _reportPost(
  BuildContext context,
  WidgetRef ref,
  SocialPostModel post,
) async {
  final reason = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => _ReportReasonSheet(authorName: post.authorName),
  );
  if (reason == null || !context.mounted) return;
  try {
    await ref
        .read(surfRepositoryProvider)
        .reportSocialContent(
          targetType: 'post',
          targetId: post.id,
          reason: reason,
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Report sent. Thanks for helping TYDES.')),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not report this post right now.')),
    );
  }
}

Future<void> _confirmAndBlockPostAuthor(
  BuildContext context,
  WidgetRef ref,
  SocialPostModel post,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Block ${post.authorName}?'),
      content: const Text(
        'You will not see their posts or profile in TYDES. You can undo this later from future safety settings.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Block'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await blockSocialUser(ref, post.userId);
  ref.invalidate(travelFeedPostsProvider);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('@${post.authorHandle ?? post.authorName} blocked.'),
    ),
  );
}

class _ReportReasonSheet extends StatelessWidget {
  const _ReportReasonSheet({required this.authorName});

  final String authorName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
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
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('Report post', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('Tell us what is wrong with $authorName’s post.'),
            const SizedBox(height: 12),
            for (final reason in const [
              'Spam or scam',
              'Harassment or hate',
              'Nudity or sexual content',
              'Dangerous event or sexual services',
            ])
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(reason),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).pop(reason),
              ),
          ],
        ),
      ),
    );
  }
}

class PostEngagementBar extends ConsumerStatefulWidget {
  const PostEngagementBar({super.key, required this.post});

  final SocialPostModel post;

  @override
  ConsumerState<PostEngagementBar> createState() => _PostEngagementBarState();
}

class SocialPostBodyPreview extends StatefulWidget {
  const SocialPostBodyPreview({
    super.key,
    required this.body,
    this.maxLines = _postBodyPreviewMaxLines,
  });

  final String body;
  final int maxLines;

  @override
  State<SocialPostBodyPreview> createState() => _SocialPostBodyPreviewState();
}

class _SocialPostBodyPreviewState extends State<SocialPostBodyPreview> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge;
    final scheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final shouldToggle = _textExceedsPreview(context, constraints, style);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.body,
              maxLines: _expanded ? null : widget.maxLines,
              overflow: _expanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: style,
            ),
            if (shouldToggle) ...[
              const SizedBox(height: 6),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    _expanded ? 'Show less' : 'Show more',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  bool _textExceedsPreview(
    BuildContext context,
    BoxConstraints constraints,
    TextStyle? style,
  ) {
    if (!constraints.hasBoundedWidth || constraints.maxWidth <= 0) {
      return widget.body.split('\n').length > widget.maxLines;
    }

    final painter = TextPainter(
      text: TextSpan(text: widget.body, style: style),
      maxLines: widget.maxLines,
      textDirection: Directionality.of(context),
    )..layout(maxWidth: constraints.maxWidth);

    return painter.didExceedMaxLines;
  }
}

class _PostEngagementBarState extends ConsumerState<PostEngagementBar>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _commentController = TextEditingController();
  final FocusNode _commentFocusNode = FocusNode();
  SocialComment? _replyTarget;

  @override
  bool get wantKeepAlive =>
      _commentController.text.isNotEmpty || _replyTarget != null;

  @override
  void initState() {
    super.initState();
    _commentController.addListener(updateKeepAlive);
  }

  @override
  void dispose() {
    _commentController.removeListener(updateKeepAlive);
    _commentController.dispose();
    _commentFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final liked = ref.watch(
      likedPostIdsProvider.select((ids) => ids.contains(widget.post.id)),
    );
    final reposted = ref.watch(
      repostedPostIdsProvider.select((ids) => ids.contains(widget.post.id)),
    );
    final likeCount = _baseLikeCount(widget.post) + (liked ? 1 : 0);
    final repostCount = _baseRepostCount(widget.post) + (reposted ? 1 : 0);
    final blockedUserIds = ref.watch(blockedUserIdsProvider);
    final postComments = ref.watch(
      postCommentsProvider.select(
        (comments) => comments[widget.post.id] ?? const <SocialComment>[],
      ),
    );
    final comments = postComments
        .where((comment) => !blockedUserIds.contains(comment.userId))
        .toList();
    final currentViewer = ref.watch(currentViewerProvider).valueOrNull;
    final canModerateComments = currentViewer?.id == widget.post.userId;
    final topLevelComments = _topLevelComments(comments);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _PostLikeButton(
              selected: liked,
              count: likeCount,
              onTap: _togglePostLike,
            ),
            const SizedBox(width: 8),
            _PostRepostButton(
              selected: reposted,
              count: repostCount,
              onTap: _toggleRepost,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _commentController,
                focusNode: _commentFocusNode,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _addComment(),
                decoration: InputDecoration(
                  hintText: 'Comment',
                  filled: true,
                  fillColor: Theme.of(context).scaffoldBackgroundColor,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _addComment,
              icon: const Icon(Icons.arrow_upward_rounded),
              style: IconButton.styleFrom(
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
              ),
              tooltip: 'Post comment',
            ),
          ],
        ),
        if (topLevelComments.isNotEmpty) ...[
          const SizedBox(height: 10),
          ...topLevelComments
              .take(2)
              .map(
                (comment) => _CommentThread(
                  comment: comment,
                  replies: _repliesForComment(comments, comment.id),
                  maxReplies: 1,
                  onViewAllReplies: _openCommentsSheet,
                  onReply: () => _startReply(comment),
                  canDeleteComment: (comment) =>
                      canModerateComments || comment.isMe,
                  onDeleteComment: _deleteComment,
                ),
              ),
          if (topLevelComments.length > 2)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _openCommentsSheet,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 34),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(
                  'View all ${topLevelComments.length} comments',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Future<void> _togglePostLike() async {
    final wasLiked = ref.read(likedPostIdsProvider).contains(widget.post.id);
    final previous = ref.read(likedPostIdsProvider);
    ref.read(likedPostIdsProvider.notifier).state = wasLiked
        ? ({...previous}..remove(widget.post.id))
        : {...previous, widget.post.id};
    try {
      final engagement = await ref
          .read(surfRepositoryProvider)
          .setPostLike(postId: widget.post.id, liked: !wasLiked);
      _applySocialEngagement(ref, engagement);
    } catch (_) {
      ref.read(likedPostIdsProvider.notifier).state = previous;
    }
  }

  void _addComment() {
    final comment = _commentController.text.trim();
    if (comment.isEmpty) return;
    if (hasBlockedContent(comment)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(contentBlockedMessage)));
      return;
    }
    unawaited(_saveComment(comment));
    _commentController.clear();
    setState(() => _replyTarget = null);
  }

  Future<void> _saveComment(String text) async {
    try {
      final engagement = await ref
          .read(surfRepositoryProvider)
          .createComment(
            postId: widget.post.id,
            text: text,
            replyToCommentId: _replyTarget?.id,
          );
      _applySocialEngagement(ref, engagement);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(postActionErrorMessage(error))));
    }
  }

  void _toggleRepost() {
    final wasReposted = ref
        .read(repostedPostIdsProvider)
        .contains(widget.post.id);
    if (wasReposted) {
      unawaited(_saveRepost(false));
      return;
    }

    final previous = ref.read(repostedPostIdsProvider);
    ref.read(repostedPostIdsProvider.notifier).state = [
      widget.post.id,
      ...previous.where((id) => id != widget.post.id),
    ];
    unawaited(_saveRepost(true, fallback: previous));
  }

  Future<void> _saveRepost(bool reposted, {List<String>? fallback}) async {
    final List<String> previous = fallback ?? ref.read(repostedPostIdsProvider);
    if (!reposted) {
      ref.read(repostedPostIdsProvider.notifier).state = [
        for (final id in previous)
          if (id != widget.post.id) id,
      ];
    }
    try {
      final engagement = await ref
          .read(surfRepositoryProvider)
          .setPostRepost(postId: widget.post.id, reposted: reposted);
      _applySocialEngagement(ref, engagement, syncVisibleReposts: false);
    } catch (_) {
      ref.read(repostedPostIdsProvider.notifier).state = previous;
    }
  }

  void _startReply(SocialComment comment) {
    final mention = _commentMentionFor(comment);
    setState(() => _replyTarget = comment);
    _commentController.text = '$mention ';
    _commentController.selection = TextSelection.collapsed(
      offset: _commentController.text.length,
    );
    _commentFocusNode.requestFocus();
  }

  void _openCommentsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _CommentsSheet(
        postId: widget.post.id,
        canModerateComments:
            ref.read(currentViewerProvider).valueOrNull?.id ==
            widget.post.userId,
      ),
    );
  }

  void _deleteComment(SocialComment comment) {
    unawaited(_deleteCommentOnBackend(comment));
  }

  Future<void> _deleteCommentOnBackend(SocialComment comment) async {
    try {
      final engagement = await ref
          .read(surfRepositoryProvider)
          .deleteComment(comment.id);
      _applySocialEngagement(ref, engagement);
    } catch (_) {
      // Ignore denied deletes for now; real moderation errors can get UI copy later.
    }
  }
}

class _CommentPreviewTile extends ConsumerWidget {
  const _CommentPreviewTile({
    required this.comment,
    this.onReply,
    this.onDelete,
    this.isReply = false,
  });

  final SocialComment comment;
  final VoidCallback? onReply;
  final VoidCallback? onDelete;
  final bool isReply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final liked = ref.watch(
      likedCommentIdsProvider.select((ids) => ids.contains(comment.id)),
    );
    final likeCount = _baseCommentLikeCount(comment) + (liked ? 1 : 0);
    final currentViewer = ref.watch(currentViewerProvider).valueOrNull;
    final isOwnComment = comment.isMe || currentViewer?.id == comment.userId;
    final showOptions = onDelete != null || !isOwnComment;
    final initial =
        comment.authorInitial ??
        (comment.authorName.trim().isEmpty
            ? '?'
            : comment.authorName.characters.first.toUpperCase());

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TydesProfileAvatar(
            size: isReply ? 26 : 32,
            displayName: comment.authorName.isEmpty
                ? initial
                : comment.authorName,
            imageUrl: comment.authorAvatarUrl,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 42),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: RichText(
                          text: TextSpan(
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: scheme.onSurface,
                                  height: 1.25,
                                ),
                            children: [
                              TextSpan(
                                text: '${comment.authorName}  ',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              TextSpan(text: comment.text),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: () => _toggleCommentLike(ref, comment.id),
                      borderRadius: BorderRadius.circular(999),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              liked
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              size: 16,
                              color: liked
                                  ? _commentLikeAccent
                                  : scheme.outline,
                            ),
                            if (likeCount > 0)
                              Text(
                                likeCount.toString(),
                                style: TextStyle(
                                  color: liked
                                      ? _commentLikeAccent
                                      : scheme.onSurfaceVariant,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  height: 1,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (showOptions) ...[
                      const SizedBox(width: 2),
                      PopupMenuButton<_CommentSafetyAction>(
                        tooltip: 'Comment options',
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        icon: Icon(
                          Icons.more_horiz_rounded,
                          color: scheme.outline,
                        ),
                        itemBuilder: (context) => [
                          if (!isOwnComment)
                            const PopupMenuItem(
                              value: _CommentSafetyAction.report,
                              child: Text('Report comment'),
                            ),
                          if (!isOwnComment)
                            const PopupMenuItem(
                              value: _CommentSafetyAction.block,
                              child: Text('Block surfer'),
                            ),
                          if (onDelete != null)
                            const PopupMenuItem(
                              value: _CommentSafetyAction.delete,
                              child: Text('Delete comment'),
                            ),
                        ],
                        onSelected: (action) {
                          switch (action) {
                            case _CommentSafetyAction.report:
                              unawaited(_reportComment(context, ref, comment));
                            case _CommentSafetyAction.block:
                              unawaited(
                                _confirmAndBlockCommentAuthor(
                                  context,
                                  ref,
                                  comment,
                                ),
                              );
                            case _CommentSafetyAction.delete:
                              onDelete?.call();
                          }
                        },
                      ),
                    ],
                  ],
                ),
                if (onReply != null)
                  TextButton(
                    onPressed: onReply,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(0, 26),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(
                      'Reply',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
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

enum _CommentSafetyAction { report, block, delete }

Future<void> _reportComment(
  BuildContext context,
  WidgetRef ref,
  SocialComment comment,
) async {
  try {
    await ref
        .read(surfRepositoryProvider)
        .reportSocialContent(
          targetType: 'comment',
          targetId: comment.id,
          reason: 'Comment report',
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Report sent. Thanks for helping TYDES.')),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not report this comment right now.')),
    );
  }
}

Future<void> _confirmAndBlockCommentAuthor(
  BuildContext context,
  WidgetRef ref,
  SocialComment comment,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Block ${comment.authorName}?'),
      content: const Text(
        'You will not see their posts, comments, profile, or messages in TYDES. You can undo this later from safety settings.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Block'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await blockSocialUser(ref, comment.userId);
  ref.invalidate(travelFeedPostsProvider);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('@${comment.authorHandle ?? comment.authorName} blocked.'),
    ),
  );
}

class _CommentThread extends StatelessWidget {
  const _CommentThread({
    required this.comment,
    required this.replies,
    required this.onReply,
    required this.canDeleteComment,
    required this.onDeleteComment,
    this.maxReplies,
    this.onViewAllReplies,
    this.expandedReplies = false,
    this.onToggleReplies,
  });

  final SocialComment comment;
  final List<SocialComment> replies;
  final VoidCallback onReply;
  final bool Function(SocialComment comment) canDeleteComment;
  final ValueChanged<SocialComment> onDeleteComment;
  final int? maxReplies;
  final VoidCallback? onViewAllReplies;
  final bool expandedReplies;
  final VoidCallback? onToggleReplies;

  @override
  Widget build(BuildContext context) {
    final visibleReplies = expandedReplies
        ? replies
        : maxReplies == null
        ? replies
        : replies.take(maxReplies!).toList();
    final hiddenReplyCount = replies.length - visibleReplies.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CommentPreviewTile(
          comment: comment,
          onReply: onReply,
          onDelete: canDeleteComment(comment)
              ? () => onDeleteComment(comment)
              : null,
        ),
        for (final reply in visibleReplies)
          Padding(
            padding: const EdgeInsets.only(left: 42),
            child: _CommentPreviewTile(
              comment: reply,
              isReply: true,
              onDelete: canDeleteComment(reply)
                  ? () => onDeleteComment(reply)
                  : null,
            ),
          ),
        if (replies.length > 1 && onToggleReplies != null)
          Padding(
            padding: const EdgeInsets.only(left: 46, bottom: 6),
            child: TextButton(
              onPressed: onToggleReplies,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 26),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                expandedReplies
                    ? 'Hide replies'
                    : hiddenReplyCount == 1
                    ? 'View 1 more reply'
                    : 'View all ${replies.length} replies',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
        if (hiddenReplyCount > 0 &&
            onViewAllReplies != null &&
            onToggleReplies == null)
          Padding(
            padding: const EdgeInsets.only(left: 46, bottom: 6),
            child: TextButton(
              onPressed: onViewAllReplies,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 26),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                hiddenReplyCount == 1
                    ? 'View 1 more reply'
                    : 'View all ${replies.length} replies',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
      ],
    );
  }
}

class _CommentsSheet extends ConsumerStatefulWidget {
  const _CommentsSheet({
    required this.postId,
    required this.canModerateComments,
  });

  final String postId;
  final bool canModerateComments;

  @override
  ConsumerState<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends ConsumerState<_CommentsSheet> {
  final TextEditingController _replyController = TextEditingController();
  final FocusNode _replyFocusNode = FocusNode();
  final Set<String> _expandedReplyCommentIds = {};
  SocialComment? _replyTarget;

  @override
  void dispose() {
    _replyController.dispose();
    _replyFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blockedUserIds = ref.watch(blockedUserIdsProvider);
    final postComments = ref.watch(
      postCommentsProvider.select(
        (comments) => comments[widget.postId] ?? const <SocialComment>[],
      ),
    );
    final comments = postComments
        .where((comment) => !blockedUserIds.contains(comment.userId))
        .toList();
    final topLevelComments = _topLevelComments(comments);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.72;

    return SafeArea(
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Comments',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Text(
                    '${topLevelComments.length}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: topLevelComments.isEmpty
                    ? Center(
                        child: Text(
                          'No comments yet.',
                          style: theme.textTheme.bodyLarge,
                        ),
                      )
                    : ListView.builder(
                        itemCount: topLevelComments.length,
                        itemBuilder: (context, index) {
                          final comment = topLevelComments[index];
                          return _CommentThread(
                            comment: comment,
                            replies: _repliesForComment(comments, comment.id),
                            maxReplies: 1,
                            expandedReplies: _expandedReplyCommentIds.contains(
                              comment.id,
                            ),
                            onToggleReplies: () {
                              setState(() {
                                if (_expandedReplyCommentIds.contains(
                                  comment.id,
                                )) {
                                  _expandedReplyCommentIds.remove(comment.id);
                                } else {
                                  _expandedReplyCommentIds.add(comment.id);
                                }
                              });
                            },
                            onReply: () => _startReply(comment),
                            canDeleteComment: (comment) =>
                                widget.canModerateComments || comment.isMe,
                            onDeleteComment: _deleteComment,
                          );
                        },
                      ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _replyController,
                      focusNode: _replyFocusNode,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _addComment(),
                      decoration: InputDecoration(
                        hintText: 'Comment',
                        filled: true,
                        fillColor: Theme.of(context).scaffoldBackgroundColor,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _addComment,
                    icon: const Icon(Icons.arrow_upward_rounded),
                    style: IconButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                    ),
                    tooltip: 'Post comment',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _startReply(SocialComment comment) {
    final mention = _commentMentionFor(comment);
    setState(() => _replyTarget = comment);
    _replyController.text = '$mention ';
    _replyController.selection = TextSelection.collapsed(
      offset: _replyController.text.length,
    );
    _replyFocusNode.requestFocus();
  }

  void _addComment() {
    final comment = _replyController.text.trim();
    if (comment.isEmpty) return;
    if (hasBlockedContent(comment)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(contentBlockedMessage)));
      return;
    }
    unawaited(_saveComment(comment));
    _replyController.clear();
    setState(() => _replyTarget = null);
  }

  Future<void> _saveComment(String text) async {
    try {
      final engagement = await ref
          .read(surfRepositoryProvider)
          .createComment(
            postId: widget.postId,
            text: text,
            replyToCommentId: _replyTarget?.id,
          );
      _applySocialEngagement(ref, engagement);
    } catch (_) {
      // We'll surface backend comment errors in a later product pass.
    }
  }

  void _deleteComment(SocialComment comment) {
    unawaited(_deleteCommentOnBackend(comment));
    setState(() {
      _expandedReplyCommentIds.remove(comment.id);
      if (_replyTarget?.id == comment.id) {
        _replyTarget = null;
        _replyController.clear();
      }
    });
  }

  Future<void> _deleteCommentOnBackend(SocialComment comment) async {
    try {
      final engagement = await ref
          .read(surfRepositoryProvider)
          .deleteComment(comment.id);
      _applySocialEngagement(ref, engagement);
    } catch (_) {
      // Ignore denied deletes for now.
    }
  }
}

int _baseLikeCount(SocialPostModel post) => post.likeCount;

int _baseRepostCount(SocialPostModel post) => post.repostCount;

List<SocialComment> _topLevelComments(List<SocialComment> comments) {
  return comments.where((comment) => comment.replyToCommentId == null).toList();
}

List<SocialComment> _repliesForComment(
  List<SocialComment> comments,
  String commentId,
) {
  return comments
      .where((comment) => comment.replyToCommentId == commentId)
      .toList();
}

int _baseCommentLikeCount(SocialComment comment) {
  const counts = {
    'comment_lina_photo_maya': 3,
    'comment_lina_photo_ari': 2,
    'comment_ari_event_lina': 4,
    'comment_ari_event_kai': 1,
    'comment_noa_event_reef': 2,
    'comment_maya_party_jo': 1,
  };
  return counts[comment.id] ?? 0;
}

String _commentMentionFor(SocialComment comment) {
  final cleaned = comment.authorName.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]+'),
    '',
  );
  if (cleaned.isEmpty || comment.isMe) return '@you';
  return '@$cleaned';
}

double _metricButtonWidth(int count) {
  final digits = count.toString().length;
  return 52 + (digits - 1).clamp(0, 4) * 8;
}

class _PostRepostButton extends StatelessWidget {
  const _PostRepostButton({
    required this.selected,
    required this.count,
    required this.onTap,
  });

  final bool selected;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: selected
          ? 'Undo repost, $count reposts'
          : 'Repost, $count reposts',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: _metricButtonWidth(count),
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.55)
                  : scheme.outlineVariant,
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Align(
                alignment: const Alignment(-0.2, 0),
                child: Icon(Icons.autorenew_rounded, size: 22, color: color),
              ),
              Positioned(
                top: 4,
                right: 8,
                child: Text(
                  count.toString(),
                  style: TextStyle(
                    color: color,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    height: 1,
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

class _PostLikeButton extends StatelessWidget {
  const _PostLikeButton({
    required this.selected,
    required this.count,
    required this.onTap,
  });

  final bool selected;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      label: selected ? 'Unlike post, $count likes' : 'Like post, $count likes',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: _metricButtonWidth(count),
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.55)
                  : scheme.outlineVariant,
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Align(
                alignment: const Alignment(-0.2, 0),
                child: Icon(
                  selected ? Icons.favorite_rounded : Icons.favorite_border,
                  size: 21,
                  color: color,
                ),
              ),
              Positioned(
                top: 4,
                right: 8,
                child: Text(
                  count.toString(),
                  style: TextStyle(
                    color: color,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    height: 1,
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

Future<void> _toggleCommentLike(WidgetRef ref, String commentId) async {
  final wasLiked = ref.read(likedCommentIdsProvider).contains(commentId);
  final previous = ref.read(likedCommentIdsProvider);
  ref.read(likedCommentIdsProvider.notifier).state = wasLiked
      ? ({...previous}..remove(commentId))
      : {...previous, commentId};
  try {
    final engagement = await ref
        .read(surfRepositoryProvider)
        .setCommentLike(commentId: commentId, liked: !wasLiked);
    _applySocialEngagement(ref, engagement);
  } catch (_) {
    ref.read(likedCommentIdsProvider.notifier).state = previous;
  }
}

Future<void> _toggleEventRsvp({
  required BuildContext context,
  required WidgetRef ref,
  required SocialPostModel post,
  required Set<String> joinedInviteIds,
  required bool joined,
}) async {
  final postId = post.id;
  final previous = joinedInviteIds;
  final next = {...joinedInviteIds};
  if (joined) {
    next.remove(postId);
  } else {
    next.add(postId);
  }
  ref.read(surfInviteRsvpProvider.notifier).state = next;
  try {
    final engagement = await ref
        .read(surfRepositoryProvider)
        .setEventRsvp(postId: postId, joined: !joined);
    _applySocialEngagement(ref, engagement);
    ref.invalidate(joinedEventChatsProvider);
    ref.read(socialRefreshKeyProvider.notifier).state++;
    if (!joined && context.mounted) {
      await showEventChatJoinPrompt(
        context,
        postId: postId,
        eventTitle: post.body,
      );
    }
  } catch (_) {
    ref.read(surfInviteRsvpProvider.notifier).state = previous;
  }
}

class SharePostButton extends StatelessWidget {
  const SharePostButton({super.key, required this.post, required this.spot});

  final SocialPostModel post;
  final SpotModel? spot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => _SharePostSheet(post: post, spot: spot),
      ),
      icon: const Icon(Icons.send_rounded),
      tooltip: 'Send post',
      color: scheme.primary,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        backgroundColor: scheme.primary.withValues(alpha: 0.08),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _SharePostSheet extends ConsumerStatefulWidget {
  const _SharePostSheet({required this.post, required this.spot});

  final SocialPostModel post;
  final SpotModel? spot;

  @override
  ConsumerState<_SharePostSheet> createState() => _SharePostSheetState();
}

class _SharePostSheetState extends ConsumerState<_SharePostSheet> {
  final TextEditingController _searchController = TextEditingController();
  final Map<String, TextEditingController> _noteControllers = {};
  final Set<String> _sentThreadIds = {};
  String _query = '';
  String? _selectedThreadId;

  @override
  void dispose() {
    _searchController.dispose();
    for (final controller in _noteControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final threads = ref.watch(directMessageThreadsProvider);
    final filteredThreads = threads.where((thread) {
      final query = _query.trim().toLowerCase();
      if (query.isEmpty) return true;
      final haystack = '${thread.name} @${thread.handle} ${thread.location}'
          .toLowerCase();
      return haystack.contains(query);
    }).toList();

    return SafeArea(
      top: false,
      child: DraggableScrollableSheet(
        initialChildSize: 0.66,
        minChildSize: 0.42,
        maxChildSize: 0.9,
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: theme.scaffoldBackgroundColor,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(30),
              ),
            ),
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text('Send to', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 6),
                _SharePostPreviewLine(post: widget.post, spot: widget.spot),
                if (_isSurfInvite(widget.post) &&
                    widget.post.visibility == 'public') ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.link),
                    label: const Text('Copy public event link'),
                    onPressed: () => copyPublicLink(
                      context,
                      publicEventLink(widget.post.id),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search messages',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Theme.of(context).cardColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  _query.isEmpty ? 'Recent' : 'Results',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                if (filteredThreads.isEmpty)
                  const _ShareEmptyState()
                else
                  ...filteredThreads.map(
                    (thread) => _ShareRecipientTile(
                      thread: thread,
                      sent: _sentThreadIds.contains(thread.id),
                      selected: _selectedThreadId == thread.id,
                      noteController: _noteControllerFor(thread.id),
                      hintText: _isSurfInvite(widget.post)
                          ? 'wanna go?'
                          : 'Add a message...',
                      onTap: () => setState(() {
                        _selectedThreadId = _selectedThreadId == thread.id
                            ? null
                            : thread.id;
                      }),
                      onSend: () => _sendToThread(thread),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  TextEditingController _noteControllerFor(String threadId) {
    return _noteControllers.putIfAbsent(threadId, TextEditingController.new);
  }

  final Set<String> _sendingThreadIds = {};

  Future<void> _sendToThread(DirectMessageThread thread) async {
    if (_sendingThreadIds.contains(thread.id) ||
        _sentThreadIds.contains(thread.id)) {
      return;
    }
    setState(() => _sendingThreadIds.add(thread.id));
    try {
      await ref
          .read(directMessageThreadsProvider.notifier)
          .sendSharedPost(
            threadId: thread.id,
            post: widget.post,
            spotName: widget.spot?.name,
            note: _noteControllerFor(thread.id).text,
          );
      if (!mounted) return;
      setState(() => _sentThreadIds.add(thread.id));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not send post. ${error.toString().replaceFirst('Bad state: ', '')}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _sendingThreadIds.remove(thread.id));
    }
  }
}

class _SharePostPreviewLine extends StatelessWidget {
  const _SharePostPreviewLine({required this.post, required this.spot});

  final SocialPostModel post;
  final SpotModel? spot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              _isSurfInvite(post)
                  ? Icons.groups_2_outlined
                  : Icons.article_outlined,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_postKindLabel(post)} from ${post.authorName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                Text(
                  spot?.name ?? 'No spot tagged',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShareRecipientTile extends StatelessWidget {
  const _ShareRecipientTile({
    required this.thread,
    required this.sent,
    required this.selected,
    required this.noteController,
    required this.hintText,
    required this.onTap,
    required this.onSend,
  });

  final DirectMessageThread thread;
  final bool sent;
  final bool selected;
  final TextEditingController noteController;
  final String hintText;
  final VoidCallback onTap;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: sent ? null : onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(22),
          border: selected
              ? Border.all(color: scheme.primary.withValues(alpha: 0.5))
              : null,
        ),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: tydesAvatarBackground,
                  child: Text(
                    thread.initial,
                    style: const TextStyle(
                      color: tydesAvatarForeground,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        thread.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      Text(
                        '@${thread.handle} • ${thread.location}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  sent
                      ? Icons.check_circle_rounded
                      : selected
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: sent ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ],
            ),
            if (selected && !sent) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: noteController,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      decoration: InputDecoration(
                        hintText: hintText,
                        filled: true,
                        fillColor: Theme.of(context).scaffoldBackgroundColor,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: onSend,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      padding: EdgeInsets.zero,
                      shape: const CircleBorder(),
                    ),
                    child: const Icon(Icons.send_rounded, size: 20),
                  ),
                ],
              ),
            ],
            if (sent) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Sent',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ShareEmptyState extends StatelessWidget {
  const _ShareEmptyState();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No recent chats found.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class SocialPostMediaCarousel extends StatefulWidget {
  const SocialPostMediaCarousel({
    super.key,
    required this.media,
    this.borderRadius = 18,
  });

  final List<SocialMediaAttachmentModel> media;
  final double borderRadius;

  @override
  State<SocialPostMediaCarousel> createState() =>
      _SocialPostMediaCarouselState();
}

@visibleForTesting
bool socialVideoShouldPlay({
  required bool active,
  required bool userPaused,
  required bool mostlyVisible,
}) => active && !userPaused && mostlyVisible;

class _SocialPostMediaCarouselState extends State<SocialPostMediaCarousel> {
  late final PageController _pageController;
  bool _restoredPage = false;
  int _pageIndex = 0;
  bool _zooming = false;

  String get _storageId =>
      'post-media:${widget.media.map((item) => item.id).join(',')}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredPage) return;
    final saved = PageStorage.maybeOf(
      context,
    )?.readState(context, identifier: _storageId);
    if (saved is int && saved >= 0 && saved < widget.media.length) {
      _pageIndex = saved;
    }
    // Retain only the selected index, not off-screen image/video controllers.
    _pageController = PageController(initialPage: _pageIndex, keepPage: false);
    _restoredPage = true;
  }

  void _pageChanged(int index) {
    setState(() => _pageIndex = index);
    PageStorage.maybeOf(
      context,
    )?.writeState(context, index, identifier: _storageId);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _showPage(int index) async {
    if (!_pageController.hasClients || index == _pageIndex) return;
    await _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _zoomChanged(bool zooming) {
    if (mounted && _zooming != zooming) {
      setState(() => _zooming = zooming);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.media;
    if (media.isEmpty) return const SizedBox.shrink();
    if (_pageIndex >= media.length) _pageIndex = media.length - 1;
    final showWebArrows = socialPostMediaCarouselShowsArrows(
      isWeb: kIsWeb,
      mediaCount: media.length,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: SocialPostMediaFrame(
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              physics: _zooming
                  ? const NeverScrollableScrollPhysics()
                  : socialPostMediaCarouselPhysics(isWeb: kIsWeb),
              itemCount: media.length,
              onPageChanged: _pageChanged,
              itemBuilder: (context, index) {
                final item = media[index];
                if (item.mediaType == 'video') {
                  final sources = videoPlaybackSources(
                    url: item.url,
                    fallbackUrl: item.fallbackUrl,
                    isWeb: kIsWeb,
                    supportsNativeHls: kIsWeb && nativeHlsPlaybackSupported(),
                  );
                  return AutoplayVideoPlayer(
                    key: ValueKey(item.id),
                    url: sources.primary,
                    fallbackUrl: sources.fallback,
                    thumbnailUrl: item.thumbnailUrl,
                    borderRadius: 0,
                    expand: true,
                    active: index == _pageIndex,
                    enableZoom: true,
                    onZoomChanged: _zoomChanged,
                  );
                }
                return PostMediaZoom(
                  key: ValueKey(item.id),
                  onZoomChanged: _zoomChanged,
                  child: _PostPhoto(url: item.url),
                );
              },
            ),
            if (showWebArrows && !_zooming) ...[
              if (_pageIndex > 0)
                Positioned(
                  left: 12,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: PostMediaArrowButton(
                      tooltip: 'Previous photo',
                      icon: Icons.chevron_left_rounded,
                      onPressed: () => _showPage(_pageIndex - 1),
                    ),
                  ),
                ),
              if (_pageIndex < media.length - 1)
                Positioned(
                  right: 12,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: PostMediaArrowButton(
                      tooltip: 'Next photo',
                      icon: Icons.chevron_right_rounded,
                      onPressed: () => _showPage(_pageIndex + 1),
                    ),
                  ),
                ),
            ],
            if (media.length > 1 && !_zooming)
              Positioned(
                left: 0,
                right: 0,
                bottom: 12,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(media.length, (index) {
                    final selected = index == _pageIndex;
                    return Semantics(
                      button: true,
                      selected: selected,
                      label: 'Media ${index + 1} of ${media.length}',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _showPage(index),
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: selected ? 8 : 6,
                            height: selected ? 8 : 6,
                            decoration: BoxDecoration(
                              color: selected
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.45),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PostPhoto extends StatefulWidget {
  const _PostPhoto({required this.url});

  final String url;

  @override
  State<_PostPhoto> createState() => _PostPhotoState();
}

class _PostPhotoState extends State<_PostPhoto> {
  Timer? _retryTimer;
  int _attempt = 0;
  bool _retryScheduled = false;

  @override
  void didUpdateWidget(covariant _PostPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _retryTimer?.cancel();
      _attempt = 0;
      _retryScheduled = false;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  String get _requestUrl {
    if (_attempt == 0) return widget.url;
    final uri = Uri.tryParse(widget.url);
    if (uri == null) return widget.url;
    return uri
        .replace(
          queryParameters: {...uri.queryParameters, 'tydes_retry': '$_attempt'},
        )
        .toString();
  }

  void _retry({bool automatic = false}) {
    if (!mounted || _attempt >= 2) return;
    _retryTimer?.cancel();
    _retryScheduled = automatic;
    _retryTimer = Timer(
      automatic ? const Duration(seconds: 1) : Duration.zero,
      () {
        if (!mounted) return;
        setState(() {
          _attempt += 1;
          _retryScheduled = false;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Image.network(
      _requestUrl,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      webHtmlElementStrategy: mediaImageStrategy(_requestUrl),
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        if (_attempt < 2 && !_retryScheduled) _retry(automatic: true);
        return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Center(
            child: TextButton.icon(
              onPressed: _attempt < 2 ? _retry : null,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(_attempt < 2 ? 'Reload photo' : 'Photo unavailable'),
            ),
          ),
        );
      },
    );
  }
}

class AutoplayVideoPlayer extends ConsumerStatefulWidget {
  const AutoplayVideoPlayer({
    super.key,
    required this.url,
    this.fallbackUrl,
    this.thumbnailUrl,
    this.borderRadius = 18,
    this.expand = false,
    this.active = true,
    this.enableZoom = false,
    this.onZoomChanged,
  });

  final String url;
  final String? fallbackUrl;
  final String? thumbnailUrl;
  final double borderRadius;
  final bool expand;
  final bool active;
  final bool enableZoom;
  final ValueChanged<bool>? onZoomChanged;

  @override
  ConsumerState<AutoplayVideoPlayer> createState() =>
      _AutoplayVideoPlayerState();
}

class _AutoplayVideoPlayerState extends ConsumerState<AutoplayVideoPlayer>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  final Set<ScrollPosition> _scrollPositions = {};
  bool _loadRequested = false;
  bool _initializing = false;
  bool _userPaused = false;
  bool _videoFailed = false;
  bool _visibilityCheckQueued = false;
  bool _pageActive = true;
  bool _foreground = true;
  bool _playbackSyncRunning = false;
  bool _playbackSyncPending = false;
  bool _soundNeedsGesture = false;
  bool _soundGestureAuthorized = false;
  bool _hasStartedPlayback = false;
  bool _policyRetryAttempted = false;
  bool _lastPlaying = false;
  bool _lastBuffering = false;
  bool _disposing = false;
  bool _usingFallback = false;
  int _playbackRevision = 0;
  int _completedLoops = 0;
  Duration _lastVideoPosition = Duration.zero;
  bool _loopLimitReached = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _scheduleVisibilityCheck();
  }

  @override
  void didUpdateWidget(covariant AutoplayVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged =
        oldWidget.url != widget.url ||
        oldWidget.fallbackUrl != widget.fallbackUrl;
    if (sourceChanged) {
      _loadGeneration++;
      final previous = _controller;
      _controller = null;
      _loadRequested = false;
      _initializing = false;
      _videoFailed = false;
      _soundGestureAuthorized = false;
      _soundNeedsGesture = false;
      _policyRetryAttempted = false;
      _hasStartedPlayback = false;
      _usingFallback = false;
      _playbackRevision++;
      previous?.removeListener(_handleVideoProgress);
      _silence(previous);
      unawaited(previous?.dispose());
    }
    if (!widget.active) {
      _playbackRevision++;
      _silence(_controller);
      return;
    }
    if (!oldWidget.active || sourceChanged) {
      _userPaused = false;
      _completedLoops = 0;
      _lastVideoPosition = Duration.zero;
      _loopLimitReached = false;
    }
    _scheduleVisibilityCheck();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageActive =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    // The nearest Scrollable is the horizontal media carousel. Listen to the
    // outer vertical feed too, including nested/retained scroll viewports.
    final nextPositions = <ScrollPosition>{};
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        nextPositions.add((element.state as ScrollableState).position);
      }
      return true;
    });
    for (final position in _scrollPositions.difference(nextPositions)) {
      position.removeListener(_handleScroll);
    }
    for (final position in nextPositions.difference(_scrollPositions)) {
      position.addListener(_handleScroll);
    }
    _scrollPositions
      ..clear()
      ..addAll(nextPositions);
    if (!_active) {
      _playbackRevision++;
      _silence(_controller);
    }
    _scheduleVisibilityCheck();
  }

  void _scheduleVisibilityCheck() {
    if (_visibilityCheckQueued) return;
    _visibilityCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckQueued = false;
      _syncPlaybackToVisibility();
    });
  }

  @override
  void dispose() {
    _disposing = true;
    _loadGeneration++;
    _playbackRevision++;
    WidgetsBinding.instance.removeObserver(this);
    for (final position in _scrollPositions) {
      position.removeListener(_handleScroll);
    }
    _controller?.removeListener(_handleVideoProgress);
    _silence(_controller);
    _controller?.dispose();
    super.dispose();
  }

  void _handleScroll() {
    _scheduleVisibilityCheck();
  }

  bool get _active => widget.active && _pageActive && _foreground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncPlaybackToVisibility();
  }

  @override
  void didChangeMetrics() => _scheduleVisibilityCheck();

  void _silence(VideoPlayerController? controller) {
    if (controller == null) return;
    // Do not trust isPlaying while an asynchronous play command is in flight.
    unawaited(controller.setVolume(0).catchError((Object _) {}));
    unawaited(controller.pause().catchError((Object _) {}));
  }

  ({Rect media, Rect viewport, Rect preloadViewport})? _visibilityGeometry() {
    if (!mounted || _disposing) return null;
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    final media = object.localToGlobal(Offset.zero) & object.size;
    var viewport = Offset.zero & MediaQuery.sizeOf(context);
    var preloadViewport = viewport;
    RenderObject child = object;
    while (child.parent != null) {
      final parent = child.parent!;
      if ((parent is RenderViewport && parent.axis == Axis.vertical) ||
          (parent is RenderShrinkWrappingViewport &&
              parent.axis == Axis.vertical)) {
        final box = parent as RenderBox;
        preloadViewport = preloadViewport.intersect(
          box.localToGlobal(Offset.zero) & box.size,
        );
      }
      final clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        viewport = viewport.intersect(
          MatrixUtils.transformRect(parent.getTransformTo(null), clip),
        );
      }
      child = parent;
    }
    return (media: media, viewport: viewport, preloadViewport: preloadViewport);
  }

  double? _visibleFraction() {
    final geometry = _visibilityGeometry();
    if (geometry == null) return null;
    if (geometry.media.isEmpty || geometry.viewport.isEmpty) return 0;
    final visible = geometry.media.intersect(geometry.viewport);
    if (visible.isEmpty) return 0;
    return visible.width *
        visible.height /
        (geometry.media.width * geometry.media.height);
  }

  bool _isMostlyVisible() =>
      (_visibleFraction() ?? 0.0) >= _videoPlayVisibilityThreshold;

  bool _isNearViewport() {
    final geometry = _visibilityGeometry();
    if (geometry == null || geometry.preloadViewport.isEmpty) return false;
    final viewport = geometry.preloadViewport;
    return geometry.media.overlaps(
      Rect.fromLTRB(
        viewport.left,
        viewport.top - viewport.height * 0.35,
        viewport.right,
        viewport.bottom + viewport.height * 0.35,
      ),
    );
  }

  String? get _usableThumbnailUrl {
    final thumbnailUrl = widget.thumbnailUrl?.trim();
    if (thumbnailUrl == null ||
        thumbnailUrl.isEmpty ||
        thumbnailUrl == widget.url) {
      return null;
    }
    return thumbnailUrl;
  }

  void _syncPlaybackToVisibility() {
    if (!mounted || _disposing) return;
    final mostlyVisible = _isMostlyVisible();
    final shouldPreload = _active && (mostlyVisible || _isNearViewport());
    final controller = _controller;
    if (!_shouldPlay) {
      _playbackRevision++;
      _silence(controller);
    }

    if (shouldPreload &&
        controller == null &&
        !_loadRequested &&
        !_initializing &&
        !_videoFailed) {
      unawaited(_loadVideo());
      return;
    }

    if (!mounted || controller == null || !controller.value.isInitialized) {
      return;
    }

    _playbackSyncPending = true;
    if (!_playbackSyncRunning) unawaited(_reconcilePlayback());
  }

  bool get _shouldPlay => socialVideoShouldPlay(
    active: _active,
    userPaused: _userPaused,
    mostlyVisible: _isMostlyVisible(),
  );

  bool get _wantsSound =>
      ref.read(videoSoundEnabledProvider) &&
      (!_soundNeedsGesture || _soundGestureAuthorized);

  bool _isCurrent(VideoPlayerController controller, int generation) =>
      mounted &&
      !_disposing &&
      generation == _loadGeneration &&
      identical(_controller, controller);

  Future<void> _reconcilePlayback() async {
    _playbackSyncRunning = true;
    VideoPlayerController? operatingController;
    try {
      while (mounted && !_disposing && _playbackSyncPending) {
        _playbackSyncPending = false;
        final controller = _controller;
        operatingController = controller;
        final generation = _loadGeneration;
        if (controller == null || !controller.value.isInitialized) continue;
        if (!_shouldPlay) {
          _silence(controller);
          continue;
        }
        final revision = _playbackRevision;
        if (!controller.value.isPlaying) {
          // New elements must first play muted. A remembered sound preference
          // is not browser permission to start an audible autoplay.
          await controller.setVolume(0);
          if (!_isCurrent(controller, generation) || !_shouldPlay) {
            _silence(controller);
            continue;
          }
          await controller.play();
          if (!_isCurrent(controller, generation) ||
              revision != _playbackRevision ||
              !_shouldPlay) {
            _silence(controller);
            continue;
          }
          _hasStartedPlayback = true;
        }
        final volume = _wantsSound ? 1.0 : 0.0;
        if (controller.value.volume != volume) {
          await controller.setVolume(volume);
        }
        // A scroll/route change can happen during either platform operation.
        if (!_isCurrent(controller, generation) ||
            revision != _playbackRevision ||
            !_shouldPlay) {
          _silence(controller);
        }
      }
    } catch (error) {
      if (operatingController != null) {
        _handlePlaybackError(operatingController, error: error);
      }
    } finally {
      _playbackSyncRunning = false;
      if (mounted && !_disposing && _playbackSyncPending) {
        unawaited(_reconcilePlayback());
      }
    }
  }

  void _handlePlaybackError(
    VideoPlayerController controller, {
    Object? error,
    bool initializationFailed = false,
  }) {
    if (!mounted || _disposing || !identical(_controller, controller)) return;
    final description =
        '${controller.value.errorDescription ?? ''} ${error ?? ''}'
            .toLowerCase();
    final policyError =
        description.contains('notallowed') ||
        description.contains('not allowed') ||
        description.contains('autoplay') ||
        description.contains("didn't interact") ||
        description.contains('user interaction') ||
        description.contains('user activation') ||
        description.contains('user gesture');
    final retryMuted = policyError && !_policyRetryAttempted;
    final sourceError =
        initializationFailed ||
        // video_player retains only PlatformException.message in its value,
        // dropping the web media-error code. Treat that error event as a source
        // failure, but exclude gesture/policy denials above from failover.
        controller.value.hasError ||
        description.contains('media_err_network') ||
        description.contains('media_err_decode') ||
        description.contains('media_err_src_not_supported') ||
        description.contains('notsupportederror');
    final fallbackUrl = widget.fallbackUrl;
    final retryFallback =
        !policyError &&
        sourceError &&
        !_usingFallback &&
        fallbackUrl != null &&
        fallbackUrl.trim().isNotEmpty &&
        fallbackUrl != widget.url;
    if (retryMuted) {
      _policyRetryAttempted = true;
      _soundNeedsGesture = true;
      _soundGestureAuthorized = false;
    }
    if (retryFallback) {
      // Try only the API-supplied alternative, once. A new element still starts
      // muted, and visibility/lifecycle checks govern whether it may play.
      _usingFallback = true;
      _soundGestureAuthorized = false;
      _lastVideoPosition = Duration.zero;
    }
    _playbackRevision++;
    _loadGeneration++;
    _controller = null;
    controller.removeListener(_handleVideoProgress);
    _silence(controller);
    unawaited(controller.dispose());
    setState(() {
      _loadRequested = false;
      _initializing = false;
      _hasStartedPlayback = false;
      _videoFailed = !retryMuted && !retryFallback;
    });
    if (retryMuted || retryFallback) _scheduleVisibilityCheck();
  }

  Widget _fittedVideo(VideoPlayerController controller) {
    final size = controller.value.size;
    if (size.width <= 0 || size.height <= 0) {
      return VideoPlayer(controller);
    }
    return ColoredBox(
      color: Colors.black,
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }

  Future<void> _loadVideo() async {
    if (_loadRequested || _initializing) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loadRequested = true;
      _initializing = true;
      _videoFailed = false;
    });

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(_usingFallback ? widget.fallbackUrl! : widget.url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _controller = controller;
    try {
      await controller.setVolume(0);
      if (!_isCurrent(controller, generation)) return;
      await controller.setLooping(true);
      if (!_isCurrent(controller, generation)) return;
      await controller.initialize();
      if (!_isCurrent(controller, generation)) return;
      controller.addListener(_handleVideoProgress);
      setState(() => _initializing = false);
      _syncPlaybackToVisibility();
    } catch (error) {
      if (!_isCurrent(controller, generation)) return;
      _handlePlaybackError(
        controller,
        error: error,
        initializationFailed: true,
      );
    }
  }

  void _handleVideoProgress() {
    final controller = _controller;
    if (!mounted || _disposing || controller == null) return;
    if (controller.value.hasError) {
      _handlePlaybackError(controller);
      return;
    }
    if (!controller.value.isInitialized) {
      return;
    }
    final value = controller.value;
    if (_lastPlaying != value.isPlaying ||
        _lastBuffering != value.isBuffering) {
      final unexpectedlyPaused = _lastPlaying && !value.isPlaying;
      _lastPlaying = value.isPlaying;
      _lastBuffering = value.isBuffering;
      if (unexpectedlyPaused &&
          kIsWeb &&
          _hasStartedPlayback &&
          !_playbackSyncRunning &&
          _shouldPlay &&
          _wantsSound &&
          !_soundGestureAuthorized &&
          !value.isBuffering) {
        // Safari may pause rather than throw when an autoplay is unmuted.
        _soundNeedsGesture = true;
        _syncPlaybackToVisibility();
      } else if (value.isPlaying && !_shouldPlay) {
        _silence(controller);
      }
      setState(() {});
    }
    final position = controller.value.position;
    if (_lastVideoPosition - position > const Duration(milliseconds: 500)) {
      _completedLoops += 1;
      if (_completedLoops >= 10 && !_loopLimitReached) {
        _loopLimitReached = true;
        _userPaused = true;
        unawaited(controller.pause());
        setState(() {});
      }
    }
    _lastVideoPosition = position;
  }

  @override
  Widget build(BuildContext context) {
    final soundEnabled = ref.watch(videoSoundEnabledProvider);
    ref.listen(videoSoundEnabledProvider, (_, _) {
      _syncPlaybackToVisibility();
    });
    final controller = _controller;
    final ready = controller?.value.isInitialized ?? false;
    final readyController = ready ? controller : null;
    final isPlaying = readyController?.value.isPlaying ?? false;
    final soundOn =
        soundEnabled && (!_soundNeedsGesture || _soundGestureAuthorized);
    final videoBody = GestureDetector(
      onTap: () {
        if (readyController == null) {
          if (!_active || !_isMostlyVisible()) return;
          _policyRetryAttempted = false;
          _loadVideo();
          return;
        }
        if (readyController.value.isPlaying) {
          _userPaused = true;
          _playbackRevision++;
          _silence(readyController);
        } else {
          if (_loopLimitReached) {
            _completedLoops = 0;
            _lastVideoPosition = Duration.zero;
            _loopLimitReached = false;
          }
          _userPaused = false;
          if (_active && _isMostlyVisible()) {
            _soundGestureAuthorized = soundEnabled;
            _soundNeedsGesture = false;
            readyController.setVolume(soundEnabled ? 1.0 : 0.0);
            unawaited(
              readyController.play().catchError((Object _) {
                _handlePlaybackError(readyController);
              }),
            );
          }
        }
        setState(() {});
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: readyController != null
                ? _fittedVideo(readyController)
                : _videoFailed
                ? Container(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: const Icon(Icons.videocam_off_outlined),
                  )
                : _VideoPosterFrame(
                    thumbnailUrl: _usableThumbnailUrl,
                    initializing: _initializing,
                  ),
          ),
          if (!isPlaying && !_videoFailed && !_initializing)
            IgnorePointer(
              child: Material(
                color: Colors.black.withValues(alpha: 0.28),
                shape: const CircleBorder(),
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              ),
            ),
          if (!ready && !_videoFailed && !_initializing)
            const Positioned(
              bottom: 14,
              child: _VideoLoadHint(label: 'Auto plays in feed'),
            ),
          if (_initializing)
            const Positioned(
              bottom: 14,
              child: _VideoLoadHint(label: 'Loading video...'),
            ),
          if (ready)
            Positioned(
              right: 10,
              bottom: 10,
              child: Material(
                color: Colors.black.withValues(alpha: 0.32),
                shape: const CircleBorder(),
                child: IconButton(
                  onPressed: () {
                    if (!_active || !_isMostlyVisible()) return;
                    final enable = !soundOn;
                    _soundGestureAuthorized = enable;
                    _soundNeedsGesture = false;
                    // Invoke under the actual tap, not from build, so Safari
                    // recognizes the user's request to hear this element.
                    readyController!.setVolume(enable ? 1.0 : 0.0);
                    if (enable && !_userPaused) {
                      unawaited(
                        readyController.play().catchError((Object _) {
                          _handlePlaybackError(readyController);
                        }),
                      );
                    }
                    ref.read(videoSoundEnabledProvider.notifier).state = enable;
                    setState(() {});
                  },
                  tooltip: soundOn ? 'Mute video' : 'Unmute video',
                  color: Colors.white,
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    soundOn
                        ? Icons.volume_up_rounded
                        : Icons.volume_off_rounded,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    final mediaBody = widget.enableZoom
        ? PostMediaZoom(onZoomChanged: widget.onZoomChanged, child: videoBody)
        : videoBody;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: widget.expand
          ? SizedBox.expand(child: mediaBody)
          : AspectRatio(
              aspectRatio: readyController?.value.aspectRatio ?? 4 / 5,
              child: mediaBody,
            ),
    );
  }
}

class _VideoLoadHint extends StatelessWidget {
  const _VideoLoadHint({this.label = 'Tap to load video'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _VideoPosterFrame extends StatelessWidget {
  const _VideoPosterFrame({
    required this.thumbnailUrl,
    required this.initializing,
  });

  final String? thumbnailUrl;
  final bool initializing;

  @override
  Widget build(BuildContext context) {
    final fallback = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: [0.0, 0.48, 0.78, 1.0],
          colors: [
            Color(0xFF07383D),
            Color(0xFF087D88),
            Color(0xFF20BBC0),
            Color(0xFFF4D277),
          ],
        ),
      ),
      child: const _TydesVideoLoader(),
    );

    if (thumbnailUrl == null) return fallback;
    return Image.network(
      thumbnailUrl!,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      webHtmlElementStrategy: mediaImageStrategy(thumbnailUrl!),
      frameBuilder: (context, child, frame, synchronous) {
        if (!synchronous && frame == null) return fallback;
        // Do not leave a repeating loader hidden behind a finished poster.
        if (!initializing) return child;
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            Container(
              color: const Color(0xFF052F34).withValues(alpha: 0.48),
              alignment: Alignment.center,
              child: const _TydesVideoLoader(compact: true),
            ),
          ],
        );
      },
      errorBuilder: (context, error, stackTrace) => fallback,
    );
  }
}

class _TydesVideoLoader extends StatefulWidget {
  const _TydesVideoLoader({this.compact = false});

  final bool compact;

  @override
  State<_TydesVideoLoader> createState() => _TydesVideoLoaderState();
}

class _TydesVideoLoaderState extends State<_TydesVideoLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
    )..repeat(reverse: true);
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _scale = Tween<double>(begin: 0.94, end: 1.03).animate(curve);
    _opacity = Tween<double>(begin: 0.72, end: 1).animate(curve);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logoSize = widget.compact ? 46.0 : 72.0;
    final ringSize = widget.compact ? 62.0 : 94.0;
    return Semantics(
      label: 'TYDES video loading',
      child: Center(
        child: ScaleTransition(
          scale: _scale,
          child: FadeTransition(
            opacity: _opacity,
            child: SizedBox.square(
              dimension: ringSize,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: CircularProgressIndicator(
                      strokeWidth: widget.compact ? 2.4 : 3,
                      color: const Color(0xFFF7DD8E),
                      backgroundColor: Colors.white.withValues(alpha: 0.28),
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.all(widget.compact ? 5 : 7),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(
                        widget.compact ? 15 : 22,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFF052F34,
                          ).withValues(alpha: 0.26),
                          blurRadius: 22,
                          offset: const Offset(0, 9),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        widget.compact ? 11 : 17,
                      ),
                      child: Image.asset(
                        'assets/branding/tydes-wave-blue-256.png',
                        width: logoSize,
                        height: logoSize,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SurfInviteActions extends ConsumerWidget {
  const SurfInviteActions({super.key, required this.post, required this.spot});

  final SocialPostModel post;
  final SpotModel? spot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!_isSurfInvite(post)) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final desktop = MediaQuery.sizeOf(context).width >= 980;
    final currentViewer = ref.watch(currentViewerProvider).valueOrNull;
    final joinedInviteIds = ref.watch(surfInviteRsvpProvider);
    final isHost = currentViewer?.id == post.userId;
    final joined = isHost || joinedInviteIds.contains(post.id);
    // The backend counts guests; the organizer is included exactly once.
    final count = 1 + post.rsvpCount;
    final details = [
      if (spot != null) spot!.name,
      if (post.meetupDate != null)
        _formatMeetupDateRange(post.meetupDate, post.meetupEndDate),
    ];

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(minHeight: desktop ? 178 : 0),
      padding: EdgeInsets.all(desktop ? 20 : 14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.16)),
      ),
      child: Column(
        mainAxisAlignment: desktop
            ? MainAxisAlignment.spaceBetween
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.groups_2_outlined,
                      size: 16,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Event',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (count > 0)
                Text(
                  '$count ${count == 1 ? 'surfer' : 'surfers'} in',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              details.join(' • '),
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: isHost
                      ? null
                      : () {
                          unawaited(
                            _toggleEventRsvp(
                              context: context,
                              ref: ref,
                              post: post,
                              joinedInviteIds: joinedInviteIds,
                              joined: joined,
                            ),
                          );
                        },
                  icon: Icon(
                    joined
                        ? Icons.check_circle_rounded
                        : Icons.waving_hand_outlined,
                  ),
                  label: Text(joined ? 'You’re in' : 'I’m in'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _showEventGoingSheet(
                    context: context,
                    post: post,
                    currentViewer: currentViewer,
                    joined: joined,
                  ),
                  icon: const Icon(Icons.people_outline),
                  label: const Text('Who’s going'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

void _showEventGoingSheet({
  required BuildContext context,
  required SocialPostModel post,
  required UserProfile? currentViewer,
  required bool joined,
}) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => _EventGoingSheet(
      post: post,
      currentViewer: currentViewer,
      joined: joined,
    ),
  );
}

class _EventGoingSheet extends ConsumerWidget {
  const _EventGoingSheet({
    required this.post,
    required this.currentViewer,
    required this.joined,
  });

  final SocialPostModel post;
  final UserProfile? currentViewer;
  final bool joined;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hostProfile = PublicProfilePreview(
      userId: post.userId,
      displayName: post.authorName,
      handle: post.authorHandle,
      avatarUrl: post.authorAvatarUrl,
      premium: post.authorPremium,
      subtitle: 'Hosting this event',
    );
    final viewerProfile = PublicProfilePreview(
      userId: currentViewer?.id ?? 'current_user',
      displayName: currentViewer?.displayName ?? 'You',
      handle: currentViewer?.handle,
      avatarUrl: currentViewer?.avatarUrl,
      premium: currentViewer?.premium ?? false,
      subtitle: 'Going to this event',
    );
    final currentViewerId = currentViewer?.id;
    final hostIsCurrentUser = currentViewerId == post.userId;
    final attendees = ref.watch(eventChatAttendeesProvider(post.id));
    final guestProfiles =
        (attendees.valueOrNull ?? const <EventAttendeeModel>[])
            .where(
              (person) =>
                  person.userId != post.userId &&
                  person.userId != currentViewerId,
            )
            .map(
              (person) => PublicProfilePreview(
                userId: person.userId,
                displayName: person.displayName,
                handle: person.handle,
                avatarUrl: person.avatarUrl,
                premium: person.premium,
                subtitle: 'Going to this event',
              ),
            )
            .toList();

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: Column(
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
              Text('Who’s going', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 18),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    _GoingPersonTile(
                      profile: hostProfile,
                      subtitle: hostIsCurrentUser && joined
                          ? 'Host  •  Going'
                          : 'Host',
                      isMe: hostIsCurrentUser,
                    ),
                    if (attendees.isLoading) const LinearProgressIndicator(),
                    if (attendees.hasError)
                      ListTile(
                        title: const Text('Could not load everyone going'),
                        trailing: TextButton(
                          onPressed: () => ref.invalidate(
                            eventChatAttendeesProvider(post.id),
                          ),
                          child: const Text('Retry'),
                        ),
                      ),
                    for (final guest in guestProfiles) ...[
                      const SizedBox(height: 10),
                      _GoingPersonTile(
                        profile: guest,
                        subtitle: 'Going',
                        isMe: false,
                      ),
                    ],
                    if (joined && !hostIsCurrentUser) ...[
                      const SizedBox(height: 10),
                      _GoingPersonTile(
                        profile: viewerProfile,
                        subtitle: 'Going',
                        isMe: true,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoingPersonTile extends StatelessWidget {
  const _GoingPersonTile({
    required this.profile,
    required this.subtitle,
    required this.isMe,
  });

  final PublicProfilePreview profile;
  final String subtitle;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        return InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () {
            _openProfileTarget(
              context: context,
              ref: ref,
              profile: profile,
              isMe: isMe,
              closeSheet: true,
            );
          },
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(22),
            ),
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
                      Text(subtitle),
                    ],
                  ),
                ),
                if (!isMe)
                  FollowButton(userId: profile.userId, compact: true)
                else
                  const Chip(label: Text('You')),
              ],
            ),
          ),
        );
      },
    );
  }
}

const _videoPlayVisibilityThreshold = 0.6;
const _postBodyPreviewMaxLines = 6;

bool _isSurfInvite(SocialPostModel post) {
  return post.postType == 'surf_plan' || post.postType == 'looking_for_buddy';
}

String _postKindLabel(SocialPostModel post) {
  return _isSurfInvite(post) ? 'event' : 'post';
}

String _formatMeetupDateRange(String? startValue, String? endValue) {
  if (startValue == null) return '';
  final start = DateTime.tryParse(startValue);
  if (start == null) return startValue;
  final end = endValue == null ? null : DateTime.tryParse(endValue);
  if (end == null || samePostDay(start, end)) {
    return _formatMeetupDate(startValue);
  }
  return shortPostDateRangeLabel(DateTimeRange(start: start, end: end));
}

String _formatMeetupDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final today = DateTime.now();
  if (samePostDay(parsed, today)) return 'Today';
  if (samePostDay(parsed, today.add(const Duration(days: 1)))) {
    return 'Tomorrow';
  }
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
  return '${months[parsed.month - 1]} ${parsed.day}';
}

String _labelForVisibility(String visibility) {
  return visibility == 'followers' ? 'Followers' : 'Public';
}

void _openProfileTarget({
  required BuildContext context,
  required WidgetRef ref,
  required PublicProfilePreview profile,
  required bool isMe,
  bool closeSheet = false,
}) {
  if (closeSheet) Navigator.of(context).pop();
  if (isMe) {
    ref.read(currentTabProvider.notifier).state = 4;
    context.go('/');
    return;
  }
  context.push('/profile/${profile.userId}', extra: profile);
}
