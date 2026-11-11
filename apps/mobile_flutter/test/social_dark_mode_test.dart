import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/social/event_chat_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

final _darkTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF079CA3),
    brightness: Brightness.dark,
  ),
  scaffoldBackgroundColor: const Color(0xFF0C1C21),
  cardColor: const Color(0xFF172D32),
);

final _post = SocialPostModel.fromJson({
  'id': 'dark-event',
  'user_id': 'owner',
  'author_name': 'Event Host',
  'author_handle': 'host',
  'post_type': 'surf_plan',
  'visibility': 'public',
  'body': 'Morning surf',
  'media': <Map<String, dynamic>>[],
  'created_at': '2026-11-11T12:00:00Z',
});

class _ChatRepository extends SurfRepository {
  _ChatRepository() : super(Dio(), DemoPersistence());

  @override
  Future<UserProfile> fetchMe() async => DemoSeed.me.copyWith(id: 'owner');

  @override
  Future<SocialPostModel> fetchSocialPost(String id) async => _post;

  @override
  Future<List<EventChatMessageModel>> fetchEventChat(String postId) async => [
    const EventChatMessageModel(
      id: 'own-message',
      postId: 'dark-event',
      userId: 'owner',
      authorName: 'Owner',
      authorHandle: 'owner',
      authorAvatarUrl: null,
      text: 'Own dark message',
      createdAt: '2026-11-11T12:00:00Z',
    ),
    const EventChatMessageModel(
      id: 'guest-message',
      postId: 'dark-event',
      userId: 'guest',
      authorName: 'Guest',
      authorHandle: 'guest',
      authorAvatarUrl: null,
      text: 'Guest dark message',
      createdAt: '2026-11-11T12:01:00Z',
    ),
  ];
}

void main() {
  testWidgets('post composer keeps its surfaces dark without changing media', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: _darkTheme,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => showCreatePostSheet(context, const []),
                child: const Text('Create'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('New post'), findsOneWidget);
    final colors = tester
        .widgetList<Container>(find.byType(Container))
        .map(
          (container) => container.decoration is BoxDecoration
              ? (container.decoration as BoxDecoration).color
              : null,
        );
    expect(colors, contains(_darkTheme.cardColor));
    expect(colors, isNot(contains(Colors.white)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('comment composer and preview do not retain cream surfaces', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentViewerProvider.overrideWith((_) async => DemoSeed.me),
          postCommentsProvider.overrideWith(
            (_) => {
              'dark-event': [
                const SocialComment(
                  id: 'comment',
                  postId: 'dark-event',
                  userId: 'guest',
                  authorName: 'Guest',
                  text: 'Ready for the swell',
                ),
              ],
            },
          ),
        ],
        child: MaterialApp(
          theme: _darkTheme,
          home: Scaffold(body: PostEngagementBar(post: _post)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration!.fillColor, _darkTheme.scaffoldBackgroundColor);
    final comment = find.byWidgetPredicate(
      (widget) =>
          widget is RichText &&
          widget.text.toPlainText().contains('Ready for the swell'),
    );
    final commentBox = tester.widget<Container>(
      find.ancestor(of: comment, matching: find.byType(Container)).first,
    );
    expect(
      (commentBox.decoration as BoxDecoration).color,
      _darkTheme.scaffoldBackgroundColor,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('event chat uses contrasting own and guest message colors', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          surfRepositoryProvider.overrideWithValue(_ChatRepository()),
        ],
        child: MaterialApp(
          theme: _darkTheme,
          home: const EventChatPage(postId: 'dark-event'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text('Own dark message')).style!.color,
      _darkTheme.colorScheme.onPrimary,
    );
    expect(
      tester.widget<Text>(find.text('Guest dark message')).style!.color,
      _darkTheme.colorScheme.onSurface,
    );
    final bubble = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('Guest dark message'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((bubble.decoration as BoxDecoration).color, _darkTheme.cardColor);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
