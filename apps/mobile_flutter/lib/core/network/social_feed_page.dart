import 'api_models.dart';

/// Feed activity has its own identity: a post and its repost are separate rows.
class SocialFeedEntry {
  const SocialFeedEntry({
    required this.entryId,
    required this.post,
    required this.kind,
    required this.activityAt,
  });

  final String entryId;
  final SocialPostModel post;
  final String kind;
  final DateTime activityAt;

  bool get isRepost => kind == 'repost';

  factory SocialFeedEntry.fromJson(Map<String, dynamic> json) {
    final id = json['entry_id'] as String;
    final kind = json['kind'] as String;
    if (id.isEmpty || (kind != 'post' && kind != 'repost')) {
      throw const FormatException('Invalid feed activity.');
    }
    return SocialFeedEntry(
      entryId: id,
      post: SocialPostModel.fromJson(json['post'] as Map<String, dynamic>),
      kind: kind,
      activityAt: DateTime.parse(json['activity_at'] as String),
    );
  }
}

class SocialFeedPage {
  const SocialFeedPage({
    required this.items,
    this.nextCursor,
    this.engagement,
    this.scopedPostIds = const [],
  });

  final List<SocialFeedEntry> items;
  final String? nextCursor;
  final SocialEngagementModel? engagement;
  final List<String> scopedPostIds;

  factory SocialFeedPage.fromJson(Map<String, dynamic> json) => SocialFeedPage(
    items: (json['items'] as List<dynamic>)
        .map((item) => SocialFeedEntry.fromJson(item as Map<String, dynamic>))
        .toList(growable: false),
    nextCursor: json['next_cursor'] as String?,
    engagement: json['engagement'] is Map<String, dynamic>
        ? SocialEngagementModel.fromJson(
            json['engagement'] as Map<String, dynamic>,
          )
        : null,
    scopedPostIds: (json['scoped_post_ids'] as List<dynamic>? ?? const [])
        .cast<String>(),
  );
}
