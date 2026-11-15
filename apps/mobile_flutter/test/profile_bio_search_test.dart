import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/settings/settings_page.dart';
import 'package:mobile_flutter/features/social/direct_message_api.dart';
import 'package:mobile_flutter/features/social/direct_messages_page.dart';
import 'package:mobile_flutter/features/social/public_profile_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';
import 'package:mobile_flutter/features/spots/spots_page.dart';

import 'auth_session_test.dart' show MemorySessions, FakeTransport, body;

UserProfile _viewer({String bio = ''}) => UserProfile.fromJson({
  'id': 'viewer',
  'email': 'viewer@example.invalid',
  'display_name': 'Viewer',
  'handle': 'viewer',
  'bio': bio,
  'surf_skill': 'skilled',
  'home_region': 'Viewer coast',
  'locale': 'en',
  'email_verified': true,
});

SocialProfileModel _profile(String? bio) => SocialProfileModel.fromJson({
  'user_id': 'other',
  'display_name': 'Other Surfer',
  'handle': 'othersurfer',
  'subtitle': bio,
  'location': 'Actual coast',
  'surf_skill': 'pro',
  'premium': true,
});

final _post = SocialPostModel.fromJson({
  'id': 'post',
  'user_id': 'other',
  'author_name': 'Other Surfer',
  'author_handle': 'othersurfer',
  'post_type': 'general',
  'visibility': 'public',
  'body': 'A real post',
  'created_at': '2026-11-15T00:00:00Z',
});

Map<String, dynamic> _thread() => {
  'id': 'thread',
  'peer_user_id': 'other',
  'peer_name': 'Other Surfer',
  'peer_handle': 'othersurfer',
  'preview': 'A real message preview',
  'updated_at': '2026-11-15T00:00:00Z',
  'request_accepted': true,
  'request_declined': false,
  'unread_count': 0,
  'messages': <Map<String, dynamic>>[],
};

class _Repository extends SurfRepository {
  _Repository({this.profiles = const []}) : super(Dio(), MemorySessions());
  final List<SocialProfileModel> profiles;

  @override
  Future<List<FriendProfileModel>> fetchFriends() async => [
    FriendProfileModel(
      id: 'other',
      displayName: 'Other Surfer',
      homeRegion: 'Actual coast',
      avatarEmoji: '',
      vibe: 'Stale friend biography',
    ),
  ];
  @override
  Future<List<SocialPostModel>> fetchSocialPosts() async => [];
  @override
  Future<List<SocialProfileModel>> fetchSocialProfiles() async => profiles;
}

ProviderContainer _container({
  UserProfile? viewer,
  List<SocialProfileModel> profiles = const [],
}) {
  final me = viewer ?? _viewer();
  final api = DirectMessageApi(
    Dio(BaseOptions(baseUrl: 'https://bio.fixture.invalid'))
      ..httpClientAdapter = FakeTransport((request) async {
        if (request.path == '/users/me') return body({'id': me.id});
        if (request.path == '/messages/threads') {
          return body({
            'threads': [_thread()],
          });
        }
        if (request.path == '/messages/threads/thread') return body(_thread());
        return body({'detail': 'No external requests in this fixture'}, 404);
      }),
    MemorySessions(),
  );
  return ProviderContainer(
    overrides: [
      surfRepositoryProvider.overrideWithValue(_Repository(profiles: profiles)),
      meProvider.overrideWith((_) async => me),
      currentViewerProvider.overrideWith((_) async => me),
      socialProfilesProvider.overrideWith((_) async => profiles),
      peopleSearchPostsProvider.overrideWith((_) async => []),
      travelFeedPostsProvider.overrideWith((_) async => [_post]),
      travelFeedSpotsProvider.overrideWith((_) async => []),
      socialPostsProvider.overrideWith((_) async => []),
      friendsProvider.overrideWith((_) async => []),
      spotsProvider.overrideWith((_) async => []),
      directMessageApiProvider.overrideWithValue(api),
      joinedEventChatsProvider.overrideWith((_) async => []),
      socialEngagementHydrationProvider.overrideWith((_) async {}),
      socialRelationshipHydrationProvider.overrideWith((_) async {}),
    ],
  );
}

Future<void> _mount(
  WidgetTester tester,
  Widget page, {
  UserProfile? viewer,
  List<SocialProfileModel> profiles = const [],
}) async {
  final container = _container(viewer: viewer, profiles: profiles);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: page),
    ),
  );
  await tester.pumpAndSettle();
}

const _staleSeed = PublicProfilePreview(
  userId: 'other',
  displayName: 'Other Surfer',
  handle: 'othersurfer',
  subtitle: 'Stale route biography',
  surfSkill: 'pro',
);

void main() {
  for (final bio in <String?>['', '   \n ', null]) {
    testWidgets('authoritative blank bio ($bio) clears stale seed and friend', (
      tester,
    ) async {
      await _mount(
        tester,
        const PublicProfilePage(userId: 'other', seedProfile: _staleSeed),
        profiles: [_profile(bio)],
      );
      expect(find.text('Stale route biography'), findsNothing);
      expect(find.text('Stale friend biography'), findsNothing);
      expect(find.textContaining('Surf traveler'), findsNothing);
      expect(find.textContaining('Actual coast'), findsOneWidget);
      expect(find.text('@othersurfer • Actual coast • Pro'), findsOneWidget);
      if (bio != null && bio.isNotEmpty) {
        expect(find.text(bio), findsNothing);
      }
    });
  }

  testWidgets('fresh authored public bio wins over stale route and friend', (
    tester,
  ) async {
    await _mount(
      tester,
      const PublicProfilePage(userId: 'other', seedProfile: _staleSeed),
      profiles: [_profile('  Local surfer and photographer.  ')],
    );
    expect(find.text('Local surfer and photographer.'), findsOneWidget);
    expect(find.text('Stale route biography'), findsNothing);
    expect(find.text('Stale friend biography'), findsNothing);
  });

  testWidgets('unknown public account does not receive a fabricated bio', (
    tester,
  ) async {
    await _mount(tester, const PublicProfilePage(userId: 'unknown'));
    expect(find.textContaining('Surf traveler'), findsNothing);
    expect(find.text('Surfer'), findsOneWidget);
  });

  for (final bio in ['', '   \n ', 'My actual biography.']) {
    testWidgets('own profile only renders an authored bio ($bio)', (
      tester,
    ) async {
      await _mount(tester, const SettingsPage(), viewer: _viewer(bio: bio));
      final header = find.byType(TydesProfileCover).first;
      final text = tester
          .widgetList<Text>(
            find.descendant(of: header, matching: find.byType(Text)),
          )
          .map((text) => text.data)
          .toList();
      if (bio.trim().isEmpty) {
        expect(text, isNot(contains(bio)));
      } else {
        expect(find.text(bio), findsOneWidget);
      }
      expect(find.textContaining('Viewer coast'), findsOneWidget);
    });
  }

  testWidgets(
    'people search shows only name and handle, retaining badge/avatar',
    (tester) async {
      await _mount(
        tester,
        const PeopleSearchPage(),
        profiles: [_profile('Real bio')],
      );
      expect(find.text('Other Surfer'), findsOneWidget);
      expect(find.text('@othersurfer'), findsOneWidget);
      expect(find.text('Real bio'), findsNothing);
      expect(find.textContaining('Actual coast'), findsNothing);
      expect(find.byType(TydesProfileAvatar), findsOneWidget);
      expect(find.byIcon(Icons.verified_rounded), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Actual coast');
      await tester.pumpAndSettle();
      expect(find.text('Other Surfer'), findsNothing);
      await tester.enterText(find.byType(TextField), '@othersurfer');
      await tester.pumpAndSettle();
      expect(find.text('Other Surfer'), findsOneWidget);
    },
  );

  testWidgets('opening a feed author does not invent a route biography', (
    tester,
  ) async {
    PublicProfilePreview? opened;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: TravelFeedSection()),
        ),
        GoRoute(
          path: '/profile/:id',
          builder: (_, state) {
            opened = state.extra! as PublicProfilePreview;
            return const Scaffold(body: Text('Opened profile'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other Surfer'));
    await tester.pumpAndSettle();
    expect(opened?.userId, 'other');
    expect(opened?.subtitle, isNull);
  });

  testWidgets('message recipient search omits bio/location but keeps matching', (
    tester,
  ) async {
    await _mount(
      tester,
      const DirectMessagesPage(),
      profiles: [_profile('Real bio')],
    );
    await tester.tap(find.byTooltip('New message'));
    await tester.pumpAndSettle();
    final sheet = find.byType(DraggableScrollableSheet);
    expect(
      find.descendant(of: sheet, matching: find.text('Other Surfer')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('@othersurfer')),
      findsOneWidget,
    );
    expect(find.text('Real bio'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && (widget.data ?? '').contains('Actual coast'),
      ),
      findsNothing,
    );
    await tester.enterText(
      find.descendant(of: sheet, matching: find.byType(TextField)),
      'Actual coast',
    );
    await tester.pumpAndSettle();
    // This is a display-only cleanup: the existing location search still works.
    expect(
      find.descendant(of: sheet, matching: find.text('Other Surfer')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text && (widget.data ?? '').contains('Actual coast'),
      ),
      findsNothing,
    );
  });

  testWidgets('opening a DM peer does not invent a route biography', (
    tester,
  ) async {
    PublicProfilePreview? opened;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) =>
              const DirectMessagesPage(initialThreadId: 'thread'),
        ),
        GoRoute(
          path: '/profile/:id',
          builder: (_, state) {
            opened = state.extra! as PublicProfilePreview;
            return const Scaffold(body: Text('Opened profile'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    final container = _container();
    addTearDown(container.dispose);
    await container.read(meProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other Surfer'));
    await tester.pumpAndSettle();
    expect(opened?.userId, 'other');
    expect(opened?.subtitle, isNull);
  });
}
