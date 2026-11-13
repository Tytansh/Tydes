import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/social_feed_page.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart' show meProvider;
import 'social_feed.dart';

// Code/data for a different login must never be merged into the current cache.
final feedEngagementAccountProvider = StateProvider<String?>((ref) => null);

void applyFeedPageEngagement(
  Ref ref,
  SocialFeedPage page, {
  required String? accountId,
  required int refreshKey,
  Set<String> preservePostIds = const {},
}) {
  final engagement = page.engagement;
  final viewer = ref.read(meProvider).valueOrNull;
  if (engagement == null ||
      accountId == null ||
      viewer?.id != accountId ||
      viewer?.emailVerified != true ||
      ref.read(socialRefreshKeyProvider) != refreshKey) {
    return;
  }

  final owner = '$accountId/$refreshKey';
  if (ref.read(feedEngagementAccountProvider) != owner) {
    ref.read(likedPostIdsProvider.notifier).state = {};
    ref.read(repostedPostIdsProvider.notifier).state = [];
    ref.read(repostActivityTimesProvider.notifier).state = {};
    ref.read(visibleRepostedPostIdsProvider.notifier).state = [];
    ref.read(visibleRepostActivityTimesProvider.notifier).state = {};
    ref.read(likedCommentIdsProvider.notifier).state = {};
    ref.read(surfInviteRsvpProvider.notifier).state = {};
    ref.read(postCommentsProvider.notifier).state = {};
    ref.read(feedEngagementAccountProvider.notifier).state = owner;
  }

  // The server scope is intersected with actual returned rows, defensively
  // preventing a malformed page from clearing unrelated cached posts.
  final returnedIds = page.items.map((entry) => entry.post.id).toSet();
  final scope = page.scopedPostIds
      .toSet()
      .intersection(returnedIds)
      .difference(preservePostIds);
  Set<String> mergeSet(Set<String> previous, Iterable<String> incoming) => {
    ...previous.difference(scope),
    ...incoming.where(scope.contains),
  };
  ref.read(likedPostIdsProvider.notifier).state = mergeSet(
    ref.read(likedPostIdsProvider),
    engagement.likedPostIds,
  );
  ref.read(surfInviteRsvpProvider.notifier).state = mergeSet(
    ref.read(surfInviteRsvpProvider),
    engagement.rsvpPostIds,
  );
  ref.read(repostedPostIdsProvider.notifier).state = mergeSet(
    ref.read(repostedPostIdsProvider).toSet(),
    engagement.repostedPostIds,
  ).toList();
  ref.read(visibleRepostedPostIdsProvider.notifier).state = mergeSet(
    ref.read(visibleRepostedPostIdsProvider).toSet(),
    engagement.repostedPostIds,
  ).toList();

  final timestamps = {
    for (final repost in engagement.reposts)
      if (scope.contains(repost.postId))
        repost.postId:
            DateTime.tryParse(repost.createdAt) ??
            DateTime.fromMillisecondsSinceEpoch(0),
  };
  Map<String, DateTime> mergeTimes(Map<String, DateTime> previous) => {
    for (final item in previous.entries)
      if (!scope.contains(item.key)) item.key: item.value,
    ...timestamps,
  };
  ref.read(repostActivityTimesProvider.notifier).state = mergeTimes(
    ref.read(repostActivityTimesProvider),
  );
  ref.read(visibleRepostActivityTimesProvider.notifier).state = mergeTimes(
    ref.read(visibleRepostActivityTimesProvider),
  );

  final previousComments = ref.read(postCommentsProvider);
  final replacedCommentIds = {
    for (final id in scope)
      for (final comment in previousComments[id] ?? const <SocialComment>[])
        comment.id,
  };
  final comments = <String, List<SocialComment>>{
    for (final id in scope) id: [],
  };
  for (final model in engagement.comments) {
    if (scope.contains(model.postId)) {
      comments[model.postId]!.add(SocialComment.fromModel(model));
    }
  }
  final returnedCommentIds = {
    for (final postComments in comments.values)
      for (final comment in postComments) comment.id,
  };
  ref.read(likedCommentIdsProvider.notifier).state = {
    ...ref.read(likedCommentIdsProvider).difference(replacedCommentIds),
    ...engagement.likedCommentIds.where(returnedCommentIds.contains),
  };
  ref.read(postCommentsProvider.notifier).state = {
    ...previousComments,
    ...comments,
  };
}
