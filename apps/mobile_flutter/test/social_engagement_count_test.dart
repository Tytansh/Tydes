import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';

void main() {
  test('new social posts default to zero real engagement', () {
    final post = SocialPostModel.fromJson({
      'id': 'post_new_video',
      'user_id': 'usr_owner',
      'author_name': 'Owner',
      'author_handle': 'owner',
      'post_type': 'general',
      'visibility': 'public',
      'body': 'Fresh upload',
      'media': <Map<String, dynamic>>[],
      'created_at': '2026-10-31T05:00:00Z',
    });

    expect(post.likeCount, 0);
    expect(post.repostCount, 0);
  });

  test('social posts use engagement counts returned by the backend', () {
    final post = SocialPostModel.fromJson({
      'id': 'post_real_engagement',
      'user_id': 'usr_owner',
      'author_name': 'Owner',
      'author_handle': 'owner',
      'post_type': 'general',
      'visibility': 'public',
      'body': 'Real engagement',
      'media': <Map<String, dynamic>>[],
      'created_at': '2026-10-31T05:00:00Z',
      'like_count': 3,
      'repost_count': 2,
    });

    expect(post.likeCount, 3);
    expect(post.repostCount, 2);
  });
}
