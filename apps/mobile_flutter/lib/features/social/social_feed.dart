import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as image_tools;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../../app/router.dart';
import 'direct_messages_page.dart';
import 'social_profile.dart';

final travelFeedPostsProvider = FutureProvider((ref) {
  ref.watch(socialRefreshKeyProvider);
  return ref.watch(surfRepositoryProvider).fetchSocialPosts();
});
final travelFeedSpotsProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchSpots(),
);
final currentViewerProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchMe(),
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
    this.authorAvatarUrl,
    this.authorInitial,
    this.replyToCommentId,
    this.isMe = false,
  });

  final String id;
  final String postId;
  final String userId;
  final String authorName;
  final String text;
  final String? authorAvatarUrl;
  final String? authorInitial;
  final String? replyToCommentId;
  final bool isMe;

  factory SocialComment.fromModel(SocialCommentModel model) => SocialComment(
    id: model.id,
    postId: model.postId,
    userId: model.userId,
    authorName: model.authorName,
    authorAvatarUrl: model.authorAvatarUrl,
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
    ref.read(visibleRepostedPostIdsProvider.notifier).state =
        engagement.repostedPostIds;
    ref.read(visibleRepostActivityTimesProvider.notifier).state =
        repostActivityTimes;
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

const demoPostComments = {
  'post_lina_canggu_photo': [
    SocialComment(
      id: 'comment_lina_photo_maya',
      postId: 'post_lina_canggu_photo',
      userId: 'friend_maya',
      authorName: 'Maya Surfer',
      authorInitial: 'M',
      text: 'That waterfall shot is unreal.',
    ),
    SocialComment(
      id: 'comment_lina_photo_ari',
      postId: 'post_lina_canggu_photo',
      userId: 'friend_ari',
      authorName: 'Ari Dawn',
      authorInitial: 'A',
      text: 'Coffee run after Echo sounds dangerous haha.',
    ),
  ],
  'post_ari_balangan_event': [
    SocialComment(
      id: 'comment_ari_event_lina',
      postId: 'post_ari_balangan_event',
      userId: 'friend_lina',
      authorName: 'Lina Reef',
      authorInitial: 'L',
      text: 'I’m keen if the wind stays light.',
    ),
    SocialComment(
      id: 'comment_ari_event_kai',
      postId: 'post_ari_balangan_event',
      userId: 'friend_kai',
      authorName: 'Kai Glass',
      authorInitial: 'K',
      text: 'Save me a spot at the warung.',
    ),
  ],
  'post_noa_arugam_event': [
    SocialComment(
      id: 'comment_noa_event_reef',
      postId: 'post_noa_arugam_event',
      userId: 'suggested_reef_milo',
      authorName: 'Reef Milo',
      authorInitial: 'R',
      text: 'Main Point sunset mission sounds good.',
    ),
  ],
  'post_maya_uluwatu_party': [
    SocialComment(
      id: 'comment_maya_party_jo',
      postId: 'post_maya_uluwatu_party',
      userId: 'friend_jo',
      authorName: 'Jo Tide',
      authorInitial: 'J',
      text: 'Drop the time when you know it.',
    ),
  ],
};

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

const demoRepostActivities = [
  RepostActivity(
    postId: 'post_ari_balangan_event',
    userId: 'friend_lina',
    displayName: 'Lina Reef',
    hoursAgo: 5,
  ),
  RepostActivity(
    postId: 'post_lina_canggu_photo',
    userId: 'friend_maya',
    displayName: 'Maya Surfer',
    hoursAgo: 7,
  ),
  RepostActivity(
    postId: 'post_noa_arugam_event',
    userId: 'friend_ari',
    displayName: 'Ari Dawn',
    hoursAgo: 9,
  ),
];

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
  });

  final bool compact;
  final bool showHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final posts = ref.watch(travelFeedPostsProvider);
    final spots = ref.watch(travelFeedSpotsProvider);
    final spotItems = spots.valueOrNull ?? const <SpotModel>[];
    ref.watch(socialEngagementHydrationProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader) ...[
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
        posts.when(
          data: (items) {
            if (items.isEmpty) return const _EmptyFeedCard();
            final repostedItems = compact
                ? const <RepostedPostItem>[]
                : repostedItemsForFeed(
                    items,
                    ref.watch(visibleRepostedPostIdsProvider),
                    ref.watch(visibleRepostActivityTimesProvider),
                  );
            final feedItems = [
              for (final item in repostedItems)
                _FeedPostItem(
                  post: item.post,
                  repostHeader: item.header,
                  activityAt: item.activityAt,
                ),
              for (final post in items)
                _FeedPostItem(post: post, activityAt: _postCreatedAt(post)),
            ]..sort((a, b) => b.activityAt.compareTo(a.activityAt));
            final shown = compact ? feedItems.take(4).toList() : feedItems;
            return Column(
              children: shown
                  .map(
                    (item) => Padding(
                      key: ValueKey(
                        '${item.repostHeader ?? 'post'}_${item.post.id}',
                      ),
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _PostCard(
                        post: item.post,
                        spots: spotItems,
                        repostHeader: item.repostHeader,
                      ),
                    ),
                  )
                  .toList(),
            );
          },
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (error, _) => Text('Could not load posts: $error'),
        ),
      ],
    );
  }
}

class _FeedPostItem {
  const _FeedPostItem({
    required this.post,
    required this.activityAt,
    this.repostHeader,
  });

  final SocialPostModel post;
  final DateTime activityAt;
  final String? repostHeader;
}

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
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.86,
      minChildSize: 0.32,
      maxChildSize: 0.94,
      builder: (context, scrollController) =>
          _CreatePostSheet(spots: spots, scrollController: scrollController),
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
    final spot = _spotForId(spots, post.spotId);
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
      subtitle: isOwnPost ? currentViewer.bio : 'Surf traveler on Tydes',
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
                    child: CircleAvatar(
                      backgroundColor: tydesAvatarBackground,
                      backgroundImage: authorAvatarUrl == null
                          ? null
                          : NetworkImage(authorAvatarUrl),
                      child: authorAvatarUrl == null
                          ? Text(
                              authorName.characters.first,
                              style: const TextStyle(
                                color: tydesAvatarForeground,
                                fontWeight: FontWeight.w800,
                              ),
                            )
                          : null,
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
                  if (isOwnPost)
                    _SharePostButton(post: post, spot: spot)
                  else
                    FollowButton(userId: post.userId, compact: true),
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
                    if (!isOwnPost) _SharePostButton(post: post, spot: spot),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              if (post.media.isNotEmpty) ...[
                SocialPostMediaCarousel(media: post.media),
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

class _PostEngagementBarState extends ConsumerState<PostEngagementBar> {
  final TextEditingController _commentController = TextEditingController();
  final FocusNode _commentFocusNode = FocusNode();
  SocialComment? _replyTarget;

  @override
  void dispose() {
    _commentController.dispose();
    _commentFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final liked = ref.watch(likedPostIdsProvider).contains(widget.post.id);
    final reposted = ref
        .watch(repostedPostIdsProvider)
        .contains(widget.post.id);
    final likeCount = _baseLikeCount(widget.post) + (liked ? 1 : 0);
    final repostCount = _baseRepostCount(widget.post) + (reposted ? 1 : 0);
    final comments =
        ref.watch(postCommentsProvider)[widget.post.id] ??
        const <SocialComment>[];
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
                  fillColor: const Color(0xFFF8F7F2),
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
                foregroundColor: Colors.white,
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
    } catch (_) {
      // Keep the composer calm; backend validation will be surfaced in a later pass.
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
    final liked = ref.watch(likedCommentIdsProvider).contains(comment.id);
    final likeCount = _baseCommentLikeCount(comment) + (liked ? 1 : 0);
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
          CircleAvatar(
            radius: isReply ? 13 : 16,
            backgroundColor: tydesAvatarBackground,
            backgroundImage: comment.authorAvatarUrl == null
                ? null
                : NetworkImage(comment.authorAvatarUrl!),
            child: comment.authorAvatarUrl == null
                ? Text(
                    initial,
                    style: TextStyle(
                      color: tydesAvatarForeground,
                      fontSize: isReply ? 10 : 12,
                      fontWeight: FontWeight.w900,
                    ),
                  )
                : null,
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
                          color: const Color(0xFFF8F7F2),
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
                    if (onDelete != null) ...[
                      const SizedBox(width: 2),
                      InkWell(
                        onTap: onDelete,
                        borderRadius: BorderRadius.circular(999),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 3,
                            vertical: 6,
                          ),
                          child: Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: scheme.outline,
                          ),
                        ),
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
    final comments =
        ref.watch(postCommentsProvider)[widget.postId] ??
        const <SocialComment>[];
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
                        fillColor: const Color(0xFFF8F7F2),
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
                      foregroundColor: Colors.white,
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

int _baseLikeCount(SocialPostModel post) {
  const counts = {
    'post_lina_canggu_photo': 18,
    'post_ari_balangan_event': 12,
    'post_kai_byron_clip': 9,
    'post_noa_arugam_event': 7,
    'post_sam_snapper_photos': 15,
    'post_maya_uluwatu_party': 11,
    'post_jo_cloud9_event': 6,
    'post_uluwatu_dawn': 14,
    'post_balangan_friends': 8,
  };
  return counts[post.id] ??
      (post.id.codeUnits.fold<int>(0, (total, unit) => total + unit) % 9) + 2;
}

int _baseRepostCount(SocialPostModel post) {
  const counts = {
    'post_lina_canggu_photo': 4,
    'post_ari_balangan_event': 3,
    'post_kai_byron_clip': 2,
    'post_noa_arugam_event': 2,
    'post_sam_snapper_photos': 5,
    'post_maya_uluwatu_party': 3,
    'post_jo_cloud9_event': 1,
    'post_uluwatu_dawn': 3,
    'post_balangan_friends': 2,
  };
  return counts[post.id] ??
      post.id.codeUnits.fold<int>(0, (total, unit) => total + unit) % 4;
}

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
  required WidgetRef ref,
  required String postId,
  required Set<String> joinedInviteIds,
  required bool joined,
}) async {
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
  } catch (_) {
    ref.read(surfInviteRsvpProvider.notifier).state = previous;
  }
}

class _SharePostButton extends StatelessWidget {
  const _SharePostButton({required this.post, required this.spot});

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
            decoration: const BoxDecoration(
              color: Color(0xFFF8F7F2),
              borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
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
                const SizedBox(height: 14),
                TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search messages',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Colors.white,
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

  void _sendToThread(DirectMessageThread thread) {
    ref
        .read(directMessageThreadsProvider.notifier)
        .sendSharedPost(
          threadId: thread.id,
          post: widget.post,
          spotName: widget.spot?.name,
          note: _noteControllerFor(thread.id).text,
        );
    setState(() => _sentThreadIds.add(thread.id));
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
        color: Colors.white,
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
          color: Colors.white,
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
                        fillColor: const Color(0xFFF8F7F2),
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

class _SocialPostMediaCarouselState extends State<SocialPostMediaCarousel> {
  late final PageController _pageController;
  int _pageIndex = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.media;
    final videos = media
        .where((item) => item.mediaType == 'video')
        .take(1)
        .toList();
    if (videos.isNotEmpty) {
      return AutoplayVideoPlayer(
        url: videos.first.url,
        borderRadius: widget.borderRadius,
      );
    }

    final photos = media.where((item) => item.mediaType == 'photo').toList();
    if (photos.isEmpty) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: AspectRatio(
        aspectRatio: 4 / 5,
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: photos.length,
              onPageChanged: (index) => setState(() => _pageIndex = index),
              itemBuilder: (context, index) {
                return _PostPhoto(url: photos[index].url);
              },
            ),
            if (photos.length > 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: 12,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(photos.length, (index) {
                    final selected = index == _pageIndex;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: selected ? 8 : 6,
                      height: selected ? 8 : 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: selected
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
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

class _PostPhoto extends StatelessWidget {
  const _PostPhoto({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: const Icon(Icons.image_not_supported_outlined),
      ),
    );
  }
}

class AutoplayVideoPlayer extends ConsumerStatefulWidget {
  const AutoplayVideoPlayer({
    super.key,
    required this.url,
    this.borderRadius = 18,
  });

  final String url;
  final double borderRadius;

  @override
  ConsumerState<AutoplayVideoPlayer> createState() =>
      _AutoplayVideoPlayerState();
}

class _AutoplayVideoPlayerState extends ConsumerState<AutoplayVideoPlayer> {
  late final VideoPlayerController _controller;
  ScrollPosition? _scrollPosition;
  bool _userPaused = false;
  bool _videoFailed = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller
      ..setLooping(true)
      ..initialize()
          .then((_) {
            final soundEnabled = ref.read(videoSoundEnabledProvider);
            _controller.setVolume(soundEnabled ? 1.0 : 0.0);
            if (mounted) {
              setState(() {});
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _syncPlaybackToVisibility();
              });
            }
          })
          .catchError((Object error) {
            if (!mounted) return null;
            setState(() => _videoFailed = true);
            return null;
          });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextPosition = Scrollable.maybeOf(context)?.position;
    if (_scrollPosition == nextPosition) return;
    _scrollPosition?.removeListener(_handleScroll);
    _scrollPosition = nextPosition;
    _scrollPosition?.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncPlaybackToVisibility();
    });
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_handleScroll);
    _controller.dispose();
    super.dispose();
  }

  void _handleScroll() {
    _syncPlaybackToVisibility();
  }

  void _syncPlaybackToVisibility() {
    if (!mounted || !_controller.value.isInitialized) return;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;

    final topLeft = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    final screenHeight = MediaQuery.of(context).size.height;
    final visibleTop = topLeft.dy.clamp(0.0, screenHeight);
    final visibleBottom = (topLeft.dy + size.height).clamp(0.0, screenHeight);
    final visibleHeight = (visibleBottom - visibleTop).clamp(0.0, size.height);
    final visibleFraction = size.height == 0
        ? 0.0
        : visibleHeight / size.height;
    final shouldPlay = visibleFraction >= 0.6 && !_userPaused;

    if (shouldPlay && !_controller.value.isPlaying) {
      _controller.play();
      if (mounted) setState(() {});
    } else if (!shouldPlay && _controller.value.isPlaying) {
      _controller.pause();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final soundEnabled = ref.watch(videoSoundEnabledProvider);
    final ready = _controller.value.isInitialized;
    final isPlaying = ready && _controller.value.isPlaying;
    final targetVolume = soundEnabled ? 1.0 : 0.0;
    if (ready && _controller.value.volume != targetVolume) {
      _controller.setVolume(targetVolume);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: AspectRatio(
        aspectRatio: ready ? _controller.value.aspectRatio : 16 / 9,
        child: GestureDetector(
          onTap: ready
              ? () {
                  if (_controller.value.isPlaying) {
                    _userPaused = true;
                    _controller.pause();
                  } else {
                    _userPaused = false;
                    _controller.play();
                  }
                  setState(() {});
                }
              : null,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: ready
                    ? VideoPlayer(_controller)
                    : _videoFailed
                    ? Container(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        alignment: Alignment.center,
                        child: const Icon(Icons.videocam_off_outlined),
                      )
                    : Container(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                      ),
              ),
              if (!isPlaying && !_videoFailed)
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
              if (ready)
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.32),
                    shape: const CircleBorder(),
                    child: IconButton(
                      onPressed: () {
                        ref.read(videoSoundEnabledProvider.notifier).state =
                            !soundEnabled;
                      },
                      color: Colors.white,
                      iconSize: 20,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        soundEnabled
                            ? Icons.volume_up_rounded
                            : Icons.volume_off_rounded,
                      ),
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

class _CreatePostSheet extends ConsumerStatefulWidget {
  const _CreatePostSheet({required this.spots, required this.scrollController});

  final List<SpotModel> spots;
  final ScrollController scrollController;

  @override
  ConsumerState<_CreatePostSheet> createState() => _CreatePostSheetState();
}

class _CreatePostSheetState extends ConsumerState<_CreatePostSheet> {
  final _bodyController = TextEditingController();
  final _imagePicker = ImagePicker();
  final List<_PostMediaDraft> _media = [];
  String _postType = 'general';
  String _visibility = 'public';
  String? _spotId;
  DateTime? _inviteDate;
  DateTime? _inviteEndDate;
  bool _submitting = false;
  String? _submitStatus;

  @override
  void dispose() {
    _bodyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final favoriteSpotIds = ref.watch(favoriteSpotIdsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isSurfInvite = _postType == 'surf_plan';
    final selectedSpot = _spotForId(widget.spots, _spotId);
    final canPost =
        !_submitting &&
        (_bodyController.text.trim().isNotEmpty ||
            _media.isNotEmpty ||
            (isSurfInvite && _spotId != null));
    final captionHint = isSurfInvite
        ? 'What’s happening, who should come, and what should people know?'
        : 'Add a caption...';

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.92,
          ),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(34)),
          ),
          child: SingleChildScrollView(
            controller: widget.scrollController,
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        isSurfInvite ? 'New event' : 'New post',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _ComposerTypeSwitch(value: _postType, onChanged: _setPostType),
                const SizedBox(height: 14),
                _ComposerMediaStage(
                  media: _media,
                  onAddMedia: _pickMedia,
                  onRemoveMedia: (media) =>
                      setState(() => _media.remove(media)),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _ComposerMetaChip(
                      icon: _visibility == 'public'
                          ? Icons.public_rounded
                          : Icons.group_outlined,
                      label: _visibility == 'public' ? 'Public' : 'Followers',
                      onTap: () => setState(() {
                        _visibility = _visibility == 'public'
                            ? 'followers'
                            : 'public';
                      }),
                    ),
                    if (widget.spots.isNotEmpty)
                      _ComposerMetaChip(
                        icon: Icons.location_on_outlined,
                        label: selectedSpot?.name ?? 'Tag spot',
                        selected: selectedSpot != null,
                        onTap: () => _openSpotTagSheet(favoriteSpotIds),
                      ),
                  ],
                ),
                if (isSurfInvite) ...[
                  const SizedBox(height: 10),
                  _InviteDateChips(
                    selectedStartDate: _inviteDate,
                    selectedEndDate: _inviteEndDate,
                    onChanged: (value) => setState(() {
                      _inviteDate = value?.start;
                      _inviteEndDate =
                          value == null || _sameDay(value.start, value.end)
                          ? null
                          : value.end;
                    }),
                  ),
                ],
                const SizedBox(height: 14),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.45),
                    ),
                  ),
                  child: TextField(
                    controller: _bodyController,
                    minLines: 4,
                    maxLines: 8,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: captionHint,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(18),
                    ),
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.25),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: canPost ? _submitPost : null,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(isSurfInvite ? 'Post event' : 'Post'),
                  ),
                ),
                const SizedBox(height: 12),
                if (_submitting)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          color: scheme.primary,
                          backgroundColor: scheme.primary.withValues(
                            alpha: 0.12,
                          ),
                          minHeight: 4,
                        ),
                      ),
                      if (_submitStatus != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _submitStatus!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _setPostType(String nextType) {
    setState(() {
      _postType = nextType;
      if (nextType == 'surf_plan') {
        _visibility = 'followers';
        _inviteDate ??= DateTime.now().add(const Duration(days: 1));
      } else {
        _inviteEndDate = null;
      }
    });
  }

  Future<void> _openSpotTagSheet(Set<String> favoriteSpotIds) async {
    final value = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _SpotTagSheet(
        spots: widget.spots,
        favoriteSpotIds: favoriteSpotIds,
        selectedSpotId: _spotId,
      ),
    );
    if (!mounted || value == null) return;
    setState(() => _spotId = value == _noSpotValue ? null : value);
  }

  Future<void> _pickMedia() async {
    final messenger = ScaffoldMessenger.of(context);
    final remainingSlots = _maxPostMediaItems - _media.length;
    if (remainingSlots <= 0) {
      messenger.showSnackBar(
        const SnackBar(content: Text('You can add up to 3 photos or videos.')),
      );
      return;
    }

    try {
      final picked = await _imagePicker.pickMultipleMedia(
        imageQuality: 78,
        limit: remainingSlots,
        requestFullMetadata: false,
      );
      if (!mounted || picked.isEmpty) return;
      await _addPickedMedia(picked, remainingSlots, messenger);
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open your photos right now.')),
      );
    }
  }

  Future<void> _addPickedMedia(
    List<XFile> picked,
    int remainingSlots,
    ScaffoldMessengerState messenger,
  ) async {
    final warnings = <String>[];
    final drafts = <_PostMediaDraft>[];
    final selected = picked.take(remainingSlots).toList();

    for (final item in selected) {
      if (_looksLikeVideo(item)) {
        final videoSize = await _pickedVideoSize(item);
        if (!mounted) return;
        if (videoSize != null && videoSize > _maxPostVideoBytes) {
          warnings.add('Video added. It may need trimming before posting.');
        }
        drafts.add(_PostMediaDraft.video(item));
        continue;
      }

      final draft = await _draftForPickedPhoto(item, warnings);
      if (!mounted) return;
      if (draft != null) drafts.add(draft);
    }

    if (drafts.isNotEmpty) {
      setState(() => _media.addAll(drafts));
    }
    if (picked.length > remainingSlots) {
      warnings.insert(0, 'Only the first 3 media items were added.');
    }
    if (warnings.isNotEmpty && mounted) {
      messenger.showSnackBar(SnackBar(content: Text(warnings.first)));
    } else if (drafts.isEmpty && mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not add that media.')),
      );
    }
  }

  Future<int?> _pickedVideoSize(XFile picked) async {
    try {
      return picked.length().timeout(const Duration(seconds: 3));
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeVideo(XFile media) {
    final mimeType = media.mimeType?.toLowerCase();
    if (mimeType != null) return mimeType.startsWith('video/');
    final path = media.path.toLowerCase();
    final name = media.name.toLowerCase();
    return path.endsWith('.mov') ||
        path.endsWith('.mp4') ||
        path.endsWith('.m4v') ||
        path.endsWith('.avi') ||
        path.endsWith('.webm') ||
        name.endsWith('.mov') ||
        name.endsWith('.mp4') ||
        name.endsWith('.m4v') ||
        name.endsWith('.avi') ||
        name.endsWith('.webm');
  }

  Future<_PostMediaDraft?> _draftForPickedPhoto(
    XFile picked,
    List<String> warnings,
  ) async {
    final mediaSize = await picked.length();

    if (mediaSize > _maxPostPhotoBytes) {
      warnings.add(
        'Photos need to be under ${_formatFileSize(_maxPostPhotoBytes)}.',
      );
      return null;
    }

    final thumbnail = await _createThumbnail(picked);
    if (thumbnail == null) {
      warnings.add('Could not add one photo. Try another image.');
      return null;
    }

    final draft = _PostPhotoDraft(fullImage: picked, thumbnail: thumbnail);
    return _PostMediaDraft.photo(draft);
  }

  Future<XFile?> _createThumbnail(XFile source) async {
    final bytes = await source.readAsBytes();
    final decoded = image_tools.decodeImage(bytes);
    if (decoded == null) return null;

    final resized = image_tools.copyResize(decoded, width: 700);
    final encoded = image_tools.encodeJpg(resized, quality: 68);
    final tempDir = await getTemporaryDirectory();
    final path =
        '${tempDir.path}/post_thumb_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final file = await File(path).writeAsBytes(encoded, flush: true);
    return XFile(
      file.path,
      name: file.uri.pathSegments.last,
      mimeType: 'image/jpeg',
    );
  }

  Future<void> _submitPost() async {
    final body = _bodyController.text.trim();
    final isSurfInvite = _postType == 'surf_plan';
    if (body.isEmpty && _media.isEmpty && !(isSurfInvite && _spotId != null)) {
      return;
    }
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _submitting = true;
      _submitStatus = _media.isEmpty ? 'Posting...' : 'Preparing upload...';
    });

    try {
      final repository = ref.read(surfRepositoryProvider);
      final media = <SocialMediaAttachmentModel>[];
      for (var index = 0; index < _media.length; index++) {
        final draft = _media[index];
        final photo = draft.photo;
        final video = draft.video;
        if (photo != null) {
          _setSubmitStatus(
            'Uploading photo ${index + 1} of ${_media.length}...',
          );
          media.add(
            await repository.uploadPostPhoto(
              image: photo.fullImage,
              thumbnail: photo.thumbnail,
            ),
          );
        } else if (video != null) {
          final videoSize = await _pickedVideoSize(video);
          if (videoSize != null && videoSize > _maxPostVideoBytes) {
            throw StateError(
              'Videos need to be under ${_formatFileSize(_maxPostVideoBytes)} for now. Try trimming this clip.',
            );
          }
          _setSubmitStatus(
            'Uploading video ${index + 1} of ${_media.length}...',
          );
          media.add(await repository.uploadPostVideo(video: video));
        }
      }

      _setSubmitStatus('Posting...');
      await repository.createSocialPost(
        body: body,
        spotId: _spotId,
        postType: _postType,
        visibility: _visibility,
        media: media,
        meetupDate: isSurfInvite && _inviteDate != null
            ? _dateOnly(_inviteDate!)
            : null,
        meetupEndDate: isSurfInvite && _inviteEndDate != null
            ? _dateOnly(_inviteEndDate!)
            : null,
      );
      ref.read(socialRefreshKeyProvider.notifier).state++;
      if (!mounted) return;
      navigator.pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitStatus = null;
      });
      messenger.showSnackBar(
        SnackBar(content: Text(_uploadErrorMessage(error))),
      );
    }
  }

  void _setSubmitStatus(String status) {
    if (!mounted) return;
    setState(() => _submitStatus = status);
  }
}

class _ComposerTypeSwitch extends StatelessWidget {
  const _ComposerTypeSwitch({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ComposerTypeOption(
              icon: Icons.chat_bubble_outline,
              label: 'Post',
              selected: value == 'general',
              onTap: () => onChanged('general'),
            ),
          ),
          Expanded(
            child: _ComposerTypeOption(
              icon: Icons.groups_2_outlined,
              label: 'Event',
              selected: value == 'surf_plan',
              onTap: () => onChanged('surf_plan'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerTypeOption extends StatelessWidget {
  const _ComposerTypeOption({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.16) : null,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerMediaStage extends StatefulWidget {
  const _ComposerMediaStage({
    required this.media,
    required this.onAddMedia,
    required this.onRemoveMedia,
  });

  final List<_PostMediaDraft> media;
  final VoidCallback onAddMedia;
  final ValueChanged<_PostMediaDraft> onRemoveMedia;

  @override
  State<_ComposerMediaStage> createState() => _ComposerMediaStageState();
}

class _ComposerMediaStageState extends State<_ComposerMediaStage> {
  late final PageController _controller;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ComposerMediaStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final itemCount = _mediaItemCount;
    if (itemCount == 0) {
      _index = 0;
      return;
    }
    if (oldWidget.media.length < itemCount) {
      _index = itemCount - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        _controller.animateToPage(
          _index,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      });
      return;
    }
    if (_index >= itemCount) {
      _index = itemCount - 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final itemCount = _mediaItemCount;
    final hasMedia = itemCount > 0;
    final canAddMedia = itemCount < _maxPostMediaItems;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 4 / 5,
              child: hasMedia
                  ? Stack(
                      children: [
                        PageView.builder(
                          controller: _controller,
                          itemCount: itemCount,
                          onPageChanged: (value) =>
                              setState(() => _index = value),
                          itemBuilder: _buildMediaPage,
                        ),
                        _ComposerRemoveButton(onTap: _removeCurrentMedia),
                        if (itemCount > 1)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 12,
                            child: _ComposerDots(
                              count: itemCount,
                              index: _index,
                            ),
                          ),
                      ],
                    )
                  : _ComposerEmptyMedia(onAddMedia: widget.onAddMedia),
            ),
            if (hasMedia && canAddMedia)
              _ComposerMediaActions(
                itemCount: itemCount,
                onAddMedia: widget.onAddMedia,
              ),
          ],
        ),
      ),
    );
  }

  int get _mediaItemCount => widget.media.length;

  Widget _buildMediaPage(BuildContext context, int index) {
    final media = widget.media[index];
    final photo = media.photo;
    if (photo != null) {
      return Image.file(
        File(photo.thumbnail.path),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      );
    }

    final video = media.video;
    if (video == null) return const SizedBox.shrink();
    return Stack(
      children: [Positioned.fill(child: _ComposerVideoPreview(video: video))],
    );
  }

  void _removeCurrentMedia() {
    widget.onRemoveMedia(widget.media[_index]);
  }
}

class _ComposerEmptyMedia extends StatelessWidget {
  const _ComposerEmptyMedia({required this.onAddMedia});

  final VoidCallback onAddMedia;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.primary.withValues(alpha: 0.06),
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(
              Icons.add_photo_alternate_outlined,
              color: scheme.primary,
              size: 30,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Add media',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            'Pick up to 3 photos or videos before you post.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: onAddMedia,
              icon: const Icon(Icons.perm_media_outlined),
              label: const Text('Add media'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerVideoPreview extends StatefulWidget {
  const _ComposerVideoPreview({required this.video});

  final XFile video;

  @override
  State<_ComposerVideoPreview> createState() => _ComposerVideoPreviewState();
}

class _ComposerVideoPreviewState extends State<_ComposerVideoPreview> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final controller = VideoPlayerController.file(File(widget.video.path));
    _controller = controller;
    controller
      ..setLooping(true)
      ..setVolume(0)
      ..initialize()
          .then((_) {
            if (!mounted) return;
            setState(() {});
          })
          .catchError((Object _) {
            if (!mounted) return null;
            setState(() => _failed = true);
            return null;
          });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _toggle() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = _controller;
    final ready = controller?.value.isInitialized ?? false;
    final playing = controller?.value.isPlaying ?? false;

    return GestureDetector(
      onTap: ready ? _toggle : null,
      child: SizedBox.expand(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: ready
                  ? FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: controller!.value.size.width,
                        height: controller.value.size.height,
                        child: VideoPlayer(controller),
                      ),
                    )
                  : Container(
                      color: scheme.surfaceContainerHighest,
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _failed
                                ? Icons.videocam_outlined
                                : Icons.movie_creation_outlined,
                            color: scheme.onSurfaceVariant,
                          ),
                          if (_failed) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Video added',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
            if (!playing)
              Material(
                color: Colors.black.withValues(alpha: 0.34),
                shape: const CircleBorder(),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ComposerRemoveButton extends StatelessWidget {
  const _ComposerRemoveButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 10,
      right: 10,
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.all(7),
            child: Icon(Icons.close, color: Colors.white, size: 18),
          ),
        ),
      ),
    );
  }
}

class _ComposerDots extends StatelessWidget {
  const _ComposerDots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (dotIndex) {
        final selected = dotIndex == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: selected ? 8 : 6,
          height: selected ? 8 : 6,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white
                : Colors.white.withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }
}

class _ComposerMediaActions extends StatelessWidget {
  const _ComposerMediaActions({
    required this.itemCount,
    required this.onAddMedia,
  });

  final int itemCount;
  final VoidCallback onAddMedia;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = '$itemCount/$_maxPostMediaItems';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onAddMedia,
          icon: const Icon(Icons.perm_media_outlined, size: 18),
          label: Text('Add media ($label)'),
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.primary,
            side: BorderSide(color: scheme.primary.withValues(alpha: 0.32)),
          ),
        ),
      ),
    );
  }
}

class _ComposerMetaChip extends StatelessWidget {
  const _ComposerMetaChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(
        icon,
        size: 17,
        color: selected ? Colors.white : scheme.primary,
      ),
      label: Text(label),
      labelStyle: TextStyle(
        color: selected ? Colors.white : scheme.onSurface,
        fontWeight: FontWeight.w800,
      ),
      backgroundColor: Colors.white,
      side: BorderSide(
        color: selected
            ? scheme.primary.withValues(alpha: 0.65)
            : scheme.outlineVariant,
      ),
      color: WidgetStateProperty.resolveWith(
        (_) => selected ? scheme.primary : Colors.white,
      ),
      onPressed: onTap,
    );
  }
}

const _noSpotValue = '__no_spot__';

class _SpotTagSheet extends StatefulWidget {
  const _SpotTagSheet({
    required this.spots,
    required this.favoriteSpotIds,
    required this.selectedSpotId,
  });

  final List<SpotModel> spots;
  final Set<String> favoriteSpotIds;
  final String? selectedSpotId;

  @override
  State<_SpotTagSheet> createState() => _SpotTagSheetState();
}

class _SpotTagSheetState extends State<_SpotTagSheet> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final selectedSpot = _spotForId(widget.spots, widget.selectedSpotId);
    final searchResults = _sortTagSpots(
      widget.spots.where((spot) {
        if (query.isEmpty) return true;
        final haystack =
            '${spot.name} ${spot.area} ${spot.region} ${spot.country}'
                .toLowerCase();
        return haystack.contains(query);
      }).toList(),
      widget.favoriteSpotIds,
    ).take(80).toList();
    final countries = _groupSpotsForTagging(
      widget.spots,
      (spot) => spot.country,
    );
    final countryNames = countries.keys.toList()
      ..sort((a, b) => _tagCountryRank(a).compareTo(_tagCountryRank(b)));

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          children: [
            Text('Tag a spot', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: 'Search spots',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _controller.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            _SpotTagTile(
              title: 'No specific spot',
              subtitle: 'Post to the general feed',
              selected: widget.selectedSpotId == null,
              onTap: () => Navigator.of(context).pop(_noSpotValue),
            ),
            const SizedBox(height: 8),
            if (query.isNotEmpty)
              ...searchResults.map(
                (spot) => _SpotTagTile(
                  title: spot.name,
                  subtitle: _spotTagSubtitle(spot),
                  selected: widget.selectedSpotId == spot.id,
                  onTap: () => Navigator.of(context).pop(spot.id),
                ),
              )
            else
              for (final country in countryNames)
                _SpotTagCountrySection(
                  country: country,
                  spots: countries[country]!,
                  selectedSpot: selectedSpot,
                  onSelected: (spotId) => Navigator.of(context).pop(spotId),
                ),
          ],
        ),
      ),
    );
  }
}

class _SpotTagCountrySection extends StatelessWidget {
  const _SpotTagCountrySection({
    required this.country,
    required this.spots,
    required this.selectedSpot,
    required this.onSelected,
  });

  final String country;
  final List<SpotModel> spots;
  final SpotModel? selectedSpot;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final regions = _groupSpotsForTagging(spots, (spot) => spot.region);
    final regionNames = _sortTagGroupNames(regions.keys);
    final selectedInside = selectedSpot?.country == country;

    return _SpotTagExpansion(
      title: country,
      subtitle: '${spots.length} breaks',
      initiallyExpanded: selectedInside,
      children: [
        for (final region in regionNames)
          _SpotTagRegionSection(
            region: region,
            spots: regions[region]!,
            selectedSpot: selectedSpot,
            onSelected: onSelected,
          ),
      ],
    );
  }
}

class _SpotTagRegionSection extends StatelessWidget {
  const _SpotTagRegionSection({
    required this.region,
    required this.spots,
    required this.selectedSpot,
    required this.onSelected,
  });

  final String region;
  final List<SpotModel> spots;
  final SpotModel? selectedSpot;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final areas = _groupSpotsForTagging(spots, (spot) => spot.area);
    final areaNames = _sortTagGroupNames(areas.keys);
    final selectedInside = selectedSpot?.region == region;

    return _SpotTagExpansion(
      title: region,
      subtitle: '${areas.length} areas · ${spots.length} breaks',
      initiallyExpanded: selectedInside,
      inset: true,
      children: [
        for (final area in areaNames)
          _SpotTagAreaSection(
            area: area,
            spots: areas[area]!,
            selectedSpot: selectedSpot,
            onSelected: onSelected,
          ),
      ],
    );
  }
}

class _SpotTagAreaSection extends StatelessWidget {
  const _SpotTagAreaSection({
    required this.area,
    required this.spots,
    required this.selectedSpot,
    required this.onSelected,
  });

  final String area;
  final List<SpotModel> spots;
  final SpotModel? selectedSpot;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final selectedInside = selectedSpot?.area == area;
    final sortedSpots = _sortTagSpots(spots, const <String>{});

    return _SpotTagExpansion(
      title: area,
      subtitle: '${spots.length} ${spots.length == 1 ? 'break' : 'breaks'}',
      initiallyExpanded: selectedInside,
      inset: true,
      children: [
        for (final spot in sortedSpots)
          _SpotTagTile(
            title: spot.name,
            subtitle: _spotTagSubtitle(spot),
            selected: selectedSpot?.id == spot.id,
            compact: true,
            onTap: () => onSelected(spot.id),
          ),
      ],
    );
  }
}

class _SpotTagExpansion extends StatelessWidget {
  const _SpotTagExpansion({
    required this.title,
    required this.subtitle,
    required this.children,
    required this.initiallyExpanded,
    this.inset = false,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final bool initiallyExpanded;
  final bool inset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: EdgeInsets.only(left: inset ? 10 : 0, bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          iconColor: scheme.primary,
          collapsedIconColor: scheme.onSurfaceVariant,
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          children: children,
        ),
      ),
    );
  }
}

class _SpotTagTile extends StatelessWidget {
  const _SpotTagTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: EdgeInsets.all(compact ? 12 : 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: selected ? Border.all(color: scheme.primary) : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

Map<String, List<SpotModel>> _groupSpotsForTagging(
  Iterable<SpotModel> spots,
  String Function(SpotModel spot) keyFor,
) {
  final grouped = <String, List<SpotModel>>{};
  for (final spot in spots) {
    final key = keyFor(spot).trim();
    grouped.putIfAbsent(key.isEmpty ? 'Other' : key, () => []).add(spot);
  }
  return grouped;
}

List<String> _sortTagGroupNames(Iterable<String> names) {
  return names.toList()..sort((a, b) {
    final byRank = _tagCountryRank(a).compareTo(_tagCountryRank(b));
    if (byRank != 0 && (byRank < 900 || _tagCountryRank(b) < 900)) {
      return byRank;
    }
    return a.compareTo(b);
  });
}

List<SpotModel> _sortTagSpots(
  List<SpotModel> spots,
  Set<String> favoriteSpotIds,
) {
  return spots..sort((a, b) {
    final favoriteCompare =
        (favoriteSpotIds.contains(b.id) ? 1 : 0) -
        (favoriteSpotIds.contains(a.id) ? 1 : 0);
    if (favoriteCompare != 0) return favoriteCompare;
    return a.name.compareTo(b.name);
  });
}

String _spotTagSubtitle(SpotModel spot) {
  return '${spot.area}, ${spot.region}, ${spot.country}';
}

int _tagCountryRank(String name) {
  const order = [
    'Australia',
    'Indonesia',
    'Sri Lanka',
    'Philippines',
    'Thailand',
    'Vietnam',
    'Malaysia',
    'Myanmar',
    'Timor-Leste',
  ];
  final index = order.indexOf(name);
  return index == -1 ? 900 : index;
}

class _InviteDateChips extends StatelessWidget {
  const _InviteDateChips({
    required this.selectedStartDate,
    required this.selectedEndDate,
    required this.onChanged,
  });

  final DateTime? selectedStartDate;
  final DateTime? selectedEndDate;
  final ValueChanged<DateTimeRange?> onChanged;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final selectedRange = selectedStartDate == null
        ? null
        : DateTimeRange(
            start: selectedStartDate!,
            end: selectedEndDate ?? selectedStartDate!,
          );
    final isSingleToday =
        selectedRange != null &&
        _sameDay(selectedRange.start, today) &&
        _sameDay(selectedRange.end, today);
    final isSingleTomorrow =
        selectedRange != null &&
        _sameDay(selectedRange.start, tomorrow) &&
        _sameDay(selectedRange.end, tomorrow);
    final calendarSelected =
        selectedRange != null && !isSingleToday && !isSingleTomorrow;
    final calendarLabel = calendarSelected
        ? _shortDateRangeLabel(selectedRange)
        : 'Pick dates';
    final options = <({String label, DateTimeRange? range})>[
      (label: 'No date yet', range: null),
      (label: 'Today', range: DateTimeRange(start: today, end: today)),
      (label: 'Tomorrow', range: DateTimeRange(start: tomorrow, end: tomorrow)),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in options)
          ChoiceChip(
            label: Text(option.label),
            selected: _sameRange(selectedRange, option.range),
            onSelected: (_) => onChanged(option.range),
          ),
        ChoiceChip(
          avatar: const Icon(Icons.calendar_month_outlined, size: 16),
          label: Text(calendarLabel),
          selected: calendarSelected,
          onSelected: (_) => _pickDate(context, today, tomorrow),
        ),
      ],
    );
  }

  Future<void> _pickDate(
    BuildContext context,
    DateTime today,
    DateTime tomorrow,
  ) async {
    final initialRange =
        selectedStartDate != null && !selectedStartDate!.isBefore(today)
        ? DateTimeRange(
            start: DateTime(
              selectedStartDate!.year,
              selectedStartDate!.month,
              selectedStartDate!.day,
            ),
            end: selectedEndDate ?? selectedStartDate!,
          )
        : DateTimeRange(start: tomorrow, end: tomorrow);
    final picked = await showDateRangePicker(
      context: context,
      helpText: 'Pick event dates',
      initialDateRange: initialRange,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
    );
    if (picked == null) return;
    onChanged(picked);
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
    final currentViewer = ref.watch(currentViewerProvider).valueOrNull;
    final joinedInviteIds = ref.watch(surfInviteRsvpProvider);
    final joined = joinedInviteIds.contains(post.id);
    final guestCount = _eventGuestProfiles(post, currentViewer?.id).length;
    final hostCount = 1;
    final count = hostCount + guestCount + (joined ? 1 : 0);
    final details = [
      if (spot != null) spot!.name,
      if (post.meetupDate != null)
        _formatMeetupDateRange(post.meetupDate, post.meetupEndDate),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.16)),
      ),
      child: Column(
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
                  color: Colors.white,
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
                  onPressed: () {
                    unawaited(
                      _toggleEventRsvp(
                        ref: ref,
                        postId: post.id,
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

class _EventGoingSheet extends StatelessWidget {
  const _EventGoingSheet({
    required this.post,
    required this.currentViewer,
    required this.joined,
  });

  final SocialPostModel post;
  final UserProfile? currentViewer;
  final bool joined;

  @override
  Widget build(BuildContext context) {
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
    final guestProfiles = _eventGuestProfiles(post, currentViewerId);

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

List<PublicProfilePreview> _eventGuestProfiles(
  SocialPostModel post,
  String? currentViewerId,
) {
  final guests = switch (post.id) {
    'post_ari_balangan_event' => [
      _eventGuest('friend_lina', 'Lina Reef', 'linareef', 'Canggu longboarder'),
      _eventGuest('friend_sam', 'Sam Lines', 'samlines', 'Gold Coast surfer'),
      _eventGuest('friend_maya', 'Maya Surfer', 'mayasurfer', 'Uluwatu crew'),
    ],
    'post_noa_arugam_event' => [
      _eventGuest('friend_jo', 'Jo Tide', 'jotide', 'Siargao traveler'),
      _eventGuest('friend_lina', 'Lina Reef', 'linareef', 'Canggu longboarder'),
    ],
    'post_maya_uluwatu_party' => [
      _eventGuest('friend_ari', 'Ari Dawn', 'aridawn', 'Uluwatu surfer'),
      _eventGuest('friend_kai', 'Kai Glass', 'kaiglass', 'Byron Bay surfer'),
      _eventGuest('friend_noa', 'Noa Current', 'noacurrent', 'Arugam Bay'),
    ],
    'post_jo_cloud9_event' => [
      _eventGuest('friend_kai', 'Kai Glass', 'kaiglass', 'Byron Bay surfer'),
      _eventGuest('friend_noa', 'Noa Current', 'noacurrent', 'Arugam Bay'),
    ],
    _ => [
      _eventGuest('friend_ari', 'Ari Dawn', 'aridawn', 'Uluwatu surfer'),
      _eventGuest('friend_lina', 'Lina Reef', 'linareef', 'Canggu longboarder'),
    ],
  };

  return guests
      .where((profile) => profile.userId != post.userId)
      .where((profile) => profile.userId != currentViewerId)
      .toList();
}

PublicProfilePreview _eventGuest(
  String userId,
  String displayName,
  String handle,
  String subtitle,
) {
  return PublicProfilePreview(
    userId: userId,
    displayName: displayName,
    handle: handle,
    subtitle: subtitle,
  );
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
                          profile.displayName.characters.first,
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

class _PostPhotoDraft {
  const _PostPhotoDraft({required this.fullImage, required this.thumbnail});

  final XFile fullImage;
  final XFile thumbnail;
}

class _PostMediaDraft {
  const _PostMediaDraft.photo(this.photo) : video = null;

  const _PostMediaDraft.video(this.video) : photo = null;

  final _PostPhotoDraft? photo;
  final XFile? video;
}

const _maxPostMediaItems = 3;
const _maxPostPhotoBytes = 15 * 1024 * 1024;
const _maxPostVideoBytes = 75 * 1024 * 1024;

bool _isSurfInvite(SocialPostModel post) {
  return post.postType == 'surf_plan' || post.postType == 'looking_for_buddy';
}

String _postKindLabel(SocialPostModel post) {
  return _isSurfInvite(post) ? 'event' : 'post';
}

bool _sameDay(DateTime? left, DateTime? right) {
  if (left == null || right == null) return left == right;
  return left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

bool _sameRange(DateTimeRange? left, DateTimeRange? right) {
  if (left == null || right == null) return left == right;
  return _sameDay(left.start, right.start) && _sameDay(left.end, right.end);
}

String _shortDateLabel(DateTime date) {
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
  return '${months[date.month - 1]} ${date.day}';
}

String _shortDateRangeLabel(DateTimeRange range) {
  if (_sameDay(range.start, range.end)) return _shortDateLabel(range.start);
  final sameMonth =
      range.start.year == range.end.year &&
      range.start.month == range.end.month;
  if (sameMonth) {
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
    return '${months[range.start.month - 1]} ${range.start.day}-${range.end.day}';
  }
  return '${_shortDateLabel(range.start)}-${_shortDateLabel(range.end)}';
}

String _dateOnly(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

String _formatMeetupDateRange(String? startValue, String? endValue) {
  if (startValue == null) return '';
  final start = DateTime.tryParse(startValue);
  if (start == null) return startValue;
  final end = endValue == null ? null : DateTime.tryParse(endValue);
  if (end == null || _sameDay(start, end)) return _formatMeetupDate(startValue);
  return _shortDateRangeLabel(DateTimeRange(start: start, end: end));
}

String _formatMeetupDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final today = DateTime.now();
  if (_sameDay(parsed, today)) return 'Today';
  if (_sameDay(parsed, today.add(const Duration(days: 1)))) return 'Tomorrow';
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

String _uploadErrorMessage(Object error) {
  if (error is StateError) {
    return error.message;
  }
  if (error is DioException) {
    if (error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionTimeout) {
      return 'Upload timed out. Try a shorter video or stronger Wi-Fi.';
    }
    final data = error.response?.data;
    if (data is Map<String, dynamic> && data['detail'] is String) {
      return data['detail'] as String;
    }
    if (error.response?.statusCode == 413) {
      return 'That file is too large. Try a shorter video or smaller photo.';
    }
  }
  return 'Upload failed. Try again.';
}

String _formatFileSize(int bytes) {
  final mb = bytes / (1024 * 1024);
  return '${mb.round()}MB';
}

SpotModel? _spotForId(List<SpotModel> spots, String? spotId) {
  if (spotId == null) return null;
  for (final spot in spots) {
    if (spot.id == spotId) return spot;
  }
  return null;
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
