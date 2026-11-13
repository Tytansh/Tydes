import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/social_feed_page.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/feed_engagement.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

final _viewer = UserProfile.fromJson({
  'id': 'viewer',
  'email': 'viewer@example.invalid',
  'display_name': 'Viewer',
  'handle': 'viewer',
  'surf_skill': 'beginner',
  'home_region': 'Bali',
  'locale': 'en',
  'email_verified': true,
});

SocialFeedPage _page(
  String id, {
  List<String> likes = const [],
  List<Map<String, dynamic>> comments = const [],
  List<String> likedComments = const [],
  List<String>? scope,
}) => SocialFeedPage.fromJson({
  'items': [
    {
      'entry_id': 'post:$id',
      'kind': 'post',
      'activity_at': '2026-11-13T00:00:00Z',
      'post': {
        'id': id,
        'user_id': 'author',
        'author_name': 'Author',
        'post_type': 'general',
        'body': 'A post',
        'created_at': '2026-11-13T00:00:00Z',
      },
    },
  ],
  'next_cursor': null,
  'scoped_post_ids': scope ?? [id],
  'engagement': {
    'liked_post_ids': likes,
    'reposted_post_ids': [],
    'reposts': [],
    'rsvp_post_ids': [],
    'liked_comment_ids': likedComments,
    'comments': comments,
  },
});

Map<String, dynamic> _comment(String id, String postId) => {
  'id': id,
  'post_id': postId,
  'user_id': 'author',
  'author_name': 'Author',
  'text': 'Comment $id',
  'created_at': '2026-11-13T00:00:00Z',
};

final _apply = Provider(
  (ref) =>
      (SocialFeedPage page, String accountId, int key) =>
          applyFeedPageEngagement(
            ref,
            page,
            accountId: accountId,
            refreshKey: key,
          ),
);

final _applyPreserving = Provider(
  (ref) =>
      (SocialFeedPage page) => applyFeedPageEngagement(
        ref,
        page,
        accountId: 'viewer',
        refreshKey: 0,
        preservePostIds: {'p1'},
      ),
);

void main() {
  late ProviderContainer container;
  setUp(() async {
    container = ProviderContainer(
      overrides: [meProvider.overrideWith((_) async => _viewer)],
    );
    await container.read(meProvider.future);
  });
  tearDown(() => container.dispose());

  test('page engagement replaces its scope without clearing other pages', () {
    container.read(feedEngagementAccountProvider.notifier).state = 'viewer/0';
    container.read(likedPostIdsProvider.notifier).state = {'p1', 'p2'};
    container.read(postCommentsProvider.notifier).state = {
      'p1': [
        SocialComment.fromModel(
          SocialCommentModel.fromJson(_comment('old1', 'p1')),
        ),
      ],
      'p2': [
        SocialComment.fromModel(
          SocialCommentModel.fromJson(_comment('keep2', 'p2')),
        ),
      ],
    };
    container.read(likedCommentIdsProvider.notifier).state = {'old1', 'keep2'};
    container.read(_apply)(
      _page('p1', comments: [_comment('new1', 'p1')], likedComments: ['new1']),
      'viewer',
      0,
    );
    expect(container.read(likedPostIdsProvider), {'p2'});
    expect(container.read(postCommentsProvider)['p1']!.single.id, 'new1');
    expect(container.read(postCommentsProvider)['p2']!.single.id, 'keep2');
    expect(container.read(likedCommentIdsProvider), {'new1', 'keep2'});
    container.read(_apply)(_page('p2', likes: ['p2']), 'viewer', 0);
    expect(container.read(postCommentsProvider)['p1']!.single.id, 'new1');
    expect(container.read(likedCommentIdsProvider), {'new1'});
  });

  test('new account generation clears previous account engagement', () {
    container.read(feedEngagementAccountProvider.notifier).state =
        'old-viewer/0';
    container.read(likedPostIdsProvider.notifier).state = {'private-old-post'};
    container.read(postCommentsProvider.notifier).state = {
      'private-old-post': [
        SocialComment.fromModel(
          SocialCommentModel.fromJson(
            _comment('private-old-comment', 'private-old-post'),
          ),
        ),
      ],
    };
    container.read(_apply)(_page('p1', likes: ['p1']), 'viewer', 0);
    expect(container.read(likedPostIdsProvider), {'p1'});
    expect(container.read(postCommentsProvider).keys, ['p1']);
  });

  test('late account or refresh-generation results cannot change state', () {
    container.read(likedPostIdsProvider.notifier).state = {'keep'};
    container.read(_apply)(_page('p1', likes: ['p1']), 'different-account', 0);
    container.read(socialRefreshKeyProvider.notifier).state = 1;
    container.read(_apply)(_page('p1', likes: ['p1']), 'viewer', 0);
    expect(container.read(likedPostIdsProvider), {'keep'});
    expect(container.read(feedEngagementAccountProvider), isNull);
  });

  test('a scope cannot clear posts absent from the returned activities', () {
    container.read(feedEngagementAccountProvider.notifier).state = 'viewer/0';
    container.read(likedPostIdsProvider.notifier).state = {'p2'};
    container.read(_apply)(_page('p1', scope: ['p2']), 'viewer', 0);
    expect(container.read(likedPostIdsProvider), {'p2'});
  });

  test('appending an older original cannot overwrite its newer local like', () {
    container.read(feedEngagementAccountProvider.notifier).state = 'viewer/0';
    container.read(likedPostIdsProvider.notifier).state = {'p1'};
    container.read(_applyPreserving)(_page('p1'));
    expect(container.read(likedPostIdsProvider), {'p1'});
  });
}
