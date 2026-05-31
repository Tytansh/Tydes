import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import 'social_feed.dart';
import 'social_profile.dart';

final _postDetailBundleProvider = FutureProvider((ref) async {
  final repository = ref.watch(surfRepositoryProvider);
  final results = await Future.wait([
    repository.fetchSocialPosts(),
    repository.fetchSpots(),
  ]);
  return _PostDetailBundle(
    posts: results[0] as List<SocialPostModel>,
    spots: results[1] as List<SpotModel>,
  );
});

class PostDetailPage extends ConsumerWidget {
  const PostDetailPage({super.key, required this.postId});

  final String postId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bundle = ref.watch(_postDetailBundleProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: bundle.when(
        data: (data) {
          final post = _postForId(data.posts, postId);
          if (post == null) {
            return const Center(child: Text('Post not found.'));
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _PostDetailCard(
                post: post,
                spot: _spotForId(data.spots, post.spotId),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Could not load post: $error')),
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
      subtitle: 'Surf traveler on Tydes',
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
                  child: CircleAvatar(
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
  const _PostDetailBundle({required this.posts, required this.spots});

  final List<SocialPostModel> posts;
  final List<SpotModel> spots;
}

SocialPostModel? _postForId(List<SocialPostModel> posts, String postId) {
  for (final post in posts) {
    if (post.id == postId) return post;
  }
  return null;
}

SpotModel? _spotForId(List<SpotModel> spots, String? spotId) {
  if (spotId == null) return null;
  for (final spot in spots) {
    if (spot.id == spotId) return spot;
  }
  return null;
}
