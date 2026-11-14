import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

SocialPostModel _post(String id) => SocialPostModel.fromJson({
  'id': id,
  'user_id': 'author',
  'author_name': 'Author',
  'post_type': 'general',
  'visibility': 'public',
  'body': id,
  'created_at': '2026-11-13T00:00:00Z',
});

void main() {
  testWidgets('a comment update does not rebuild another post engagement bar', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        currentViewerProvider.overrideWith(
          (_) async => UserProfile.fromJson({
            'id': 'viewer',
            'email': 'viewer@example.invalid',
            'display_name': 'Viewer',
            'handle': 'viewer',
            'surf_skill': 'beginner',
            'home_region': 'Bali',
            'locale': 'en',
            'email_verified': true,
          }),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                PostEngagementBar(
                  key: const ValueKey('one'),
                  post: _post('one'),
                ),
                PostEngagementBar(
                  key: const ValueKey('two'),
                  post: _post('two'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final firstField = find
        .descendant(
          of: find.byKey(const ValueKey('one')),
          matching: find.byType(TextField),
        )
        .first;
    final secondField = find
        .descendant(
          of: find.byKey(const ValueKey('two')),
          matching: find.byType(TextField),
        )
        .first;
    final beforeFirst = tester.widget<TextField>(firstField);
    final beforeSecond = tester.widget<TextField>(secondField);
    await tester.enterText(secondField, 'Unsaved draft');
    await tester.pump();
    container.read(postCommentsProvider.notifier).state = {
      'one': [
        const SocialComment(
          id: 'comment-one',
          postId: 'one',
          userId: 'other',
          authorName: 'Other',
          text: 'A new comment',
        ),
      ],
    };
    await tester.pump();
    expect(
      identical(tester.widget<TextField>(firstField), beforeFirst),
      isFalse,
    );
    expect(
      identical(tester.widget<TextField>(secondField), beforeSecond),
      isTrue,
    );
    expect(
      tester.widget<TextField>(secondField).controller!.text,
      'Unsaved draft',
    );
    expect(tester.takeException(), isNull);
  });
}
