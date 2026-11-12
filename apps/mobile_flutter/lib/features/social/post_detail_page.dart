import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error_message.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../auth/auth_return_path.dart';
import '../public_previews/public_link_button.dart';
import 'social_feed.dart';
import 'social_profile.dart';

final _postDetailBundleProvider = FutureProvider.autoDispose
    .family<_PostDetailBundle, String>((ref, postId) async {
      ref.watch(socialRefreshKeyProvider);
      final repository = ref.watch(surfRepositoryProvider);
      final post = await repository.fetchSocialPost(postId);
      final spot = post.spotId == null
          ? null
          : await repository.fetchSpot(post.spotId!);
      return _PostDetailBundle(post: post, spot: spot);
    });

class PostDetailPage extends ConsumerWidget {
  const PostDetailPage({super.key, required this.postId});

  final String postId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bundle = ref.watch(_postDetailBundleProvider(postId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Post'),
        leading: IconButton(
          tooltip: 'Back to TYDES',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        ),
        actions: [
          if (bundle.valueOrNull?.post.visibility == 'public' &&
              (bundle.valueOrNull?.post.postType == 'surf_plan' ||
                  bundle.valueOrNull?.post.postType == 'looking_for_buddy'))
            CopyPublicLinkButton(url: publicEventLink(postId)),
        ],
      ),
      body: bundle.when(
        data: (data) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [_PostDetailCard(post: data.post, spot: data.spot)],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text(friendlyLoadErrorMessage(error, label: 'post'))),
      ),
    );
  }
}

class _PostDetailCard extends StatelessWidget {
  const _PostDetailCard({required this.post, required this.spot});

  final SocialPostModel post;
  final SpotModel? spot;

  @override
  Widget build(BuildContext context) {
    final profile = PublicProfilePreview(
      userId: post.userId,
      displayName: post.authorName,
      handle: post.authorHandle,
      avatarUrl: post.authorAvatarUrl,
      premium: post.authorPremium,
      subtitle: 'Surf traveler on TYDES',
    );
    final isEvent =
        post.postType == 'surf_plan' || post.postType == 'looking_for_buddy';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => context.push(
                    '/profile/${profile.userId}',
                    extra: profile,
                  ),
                  child: TydesProfileAvatar(
                    size: 40,
                    displayName: profile.displayName,
                    imageUrl: profile.avatarUrl,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => context.push(
                      '/profile/${profile.userId}',
                      extra: profile,
                    ),
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
            if (post.body.isNotEmpty)
              Text(post.body, style: Theme.of(context).textTheme.bodyLarge),
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

class _PostDetailBundle {
  const _PostDetailBundle({required this.post, required this.spot});

  final SocialPostModel post;
  final SpotModel? spot;
}
