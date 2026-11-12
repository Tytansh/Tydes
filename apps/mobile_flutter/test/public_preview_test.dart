import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/public_preview_models.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/auth/auth_page.dart';
import 'package:mobile_flutter/features/auth/auth_return_path.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/public_previews/public_preview_page.dart';
import 'package:mobile_flutter/features/social/post_detail_page.dart';
import 'package:mobile_flutter/features/spots/spot_detail_page.dart';

final _spot = PublicSpotPreview.fromJson({
  'id': 'spot_test',
  'name': 'Uluwatu Peak',
  'country': 'Indonesia',
  'region': 'Bali',
  'area': 'Uluwatu',
  'summary': 'A powerful reef break.',
  'difficulty': 'advanced',
  'best_months': ['May', 'June'],
});
PublicEventPreview _event({bool ended = false, bool dated = true}) =>
    PublicEventPreview.fromJson({
      'id': 'event_test',
      'body': 'Sunset surf\nMeet at the beach.',
      'meetup_date': dated ? '2026-11-15' : null,
      'meetup_end_date': null,
      'ended': ended,
      'host': {'name': 'Maya Surfer', 'handle': 'maya', 'avatar_url': null},
      'spot': null,
    });

class _Repo extends SurfRepository {
  _Repo() : super(Dio(), DemoPersistence());
  int privateReads = 0;
  UserProfile me = DemoSeed.me.copyWith(
    displayName: 'Current Surfer',
    handle: 'surfer',
    surfSkill: 'intermediate',
    emailVerified: true,
  );
  @override
  Future<UserProfile> fetchMe() async => me;
  @override
  Future<SpotModel> fetchSpot(String spotId) async {
    privateReads++;
    throw StateError('Private spot reads are not permitted in this test.');
  }

  @override
  Future<SocialPostModel> fetchSocialPost(String id) async {
    privateReads++;
    throw StateError('Private event reads are not permitted in this test.');
  }

  @override
  Future<UserProfile> login(
    String email,
    String locale, {
    String? password,
  }) async => me;
  @override
  Future<UserProfile> updateProfile({
    required String displayName,
    required String handle,
    required String bio,
    required String surfSkill,
    required String homeRegion,
    String? avatarUrl,
    String? avatarMediaId,
    String? coverUrl,
    String? coverMediaId,
  }) async => me = me.copyWith(
    displayName: displayName,
    handle: handle,
    bio: bio,
    surfSkill: surfSkill,
    homeRegion: homeRegion,
  );
}

void main() {
  test('auth return destination only permits known internal item routes', () {
    expect(safeAuthReturnPath('/post/event_test'), '/post/event_test');
    expect(safeAuthReturnPath('/spot/spot_test'), '/spot/spot_test');
    expect(safeAuthReturnPath('/admin'), '/admin');
    for (final value in [
      null,
      'https://evil.example',
      '//evil.example',
      '/post/../admin',
      '/post/id?next=https://evil.example',
      '/post/id#x',
    ]) {
      expect(safeAuthReturnPath(value), '/');
    }
    expect(
      Uri.parse(loginForPath('/post/event_test')).queryParameters['next'],
      '/post/event_test',
    );
    expect(publicSpotLink('spot_test'), 'https://tydes.io/#/spot/spot_test');
    expect(publicEventLink('event_test'), 'https://tydes.io/#/post/event_test');
  });

  for (final scenario in [
    (event: false, blocked: false),
    (event: true, blocked: false),
    (event: false, blocked: true),
    (event: true, blocked: true),
  ]) {
    final event = scenario.event;
    testWidgets(
      '${scenario.blocked ? 'verification latch with cached verified' : 'unverified complete'} account keeps shared ${event ? 'event' : 'spot'} public without private reads',
      (tester) async {
        final repo = _Repo();
        repo.me = repo.me.copyWith(
          emailVerified: scenario.blocked,
          premium: true,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              surfRepositoryProvider.overrideWithValue(repo),
              emailVerificationRequiredTokenProvider.overrideWith(
                (_) => scenario.blocked ? 'latched-test-session' : null,
              ),
              publicSpotPreviewProvider(
                'spot_test',
              ).overrideWith((_) async => _spot),
              publicEventPreviewProvider(
                'event_test',
              ).overrideWith((_) async => _event()),
            ],
            child: MaterialApp(
              home: event
                  ? const SharedEventPage(postId: 'event_test')
                  : const SharedSpotPage(spotId: 'spot_test'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(event ? 'Hosted by Maya Surfer' : 'A powerful reef break.'),
          findsOneWidget,
        );
        expect(find.byType(SpotDetailPage), findsNothing);
        expect(find.byType(PostDetailPage), findsNothing);
        expect(find.text('Join now'), findsNothing);
        expect(find.text("Who's going"), findsNothing);
        expect(find.text('Group chat'), findsNothing);
        expect(repo.privateReads, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [390.0, 1440.0]) {
    testWidgets('guest can read shared spot before login at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [
          meProvider.overrideWith(
            (_) => Future.error(StateError('Sign in required')),
          ),
          publicSpotPreviewProvider(
            'spot_test',
          ).overrideWith((_) async => _spot),
        ],
      );
      addTearDown(container.dispose);
      final router = container.read(appRouterProvider);
      router.go('/spot/spot_test');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Uluwatu Peak'), findsOneWidget);
      expect(find.text('A powerful reef break.'), findsOneWidget);
      expect(find.byType(AuthPage), findsNothing);
      expect(tester.takeException(), isNull);
      final button = find.text('Sign in to explore this spot');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.queryParameters['next'],
        '/spot/spot_test',
      );
      expect(find.byType(AuthPage), findsOneWidget);
    });
  }

  testWidgets(
    'guest event has host and date, no joining or chat before sign in',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/post/event_test',
        routes: [
          GoRoute(
            path: '/post/:id',
            builder: (_, _) => const SharedEventPage(postId: 'event_test'),
          ),
          GoRoute(
            path: '/login',
            builder: (_, state) =>
                Text('Return to ${state.uri.queryParameters['next']}'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            meProvider.overrideWith(
              (_) => Future.error(StateError('Sign in required')),
            ),
            publicEventPreviewProvider(
              'event_test',
            ).overrideWith((_) async => _event()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Hosted by Maya Surfer'), findsOneWidget);
      expect(find.text('@maya'), findsOneWidget);
      expect(find.text('Sun, Nov 15, 2026'), findsOneWidget);
      expect(find.text('Join now'), findsNothing);
      expect(find.text("Who's going"), findsNothing);
      expect(find.text('Group chat'), findsNothing);
      await tester.ensureVisible(find.text('Sign in to join event'));
      await tester.tap(find.text('Sign in to join event'));
      await tester.pumpAndSettle();
      expect(find.text('Return to /post/event_test'), findsOneWidget);
    },
  );

  testWidgets('private or missing event shows unavailable, not demo content', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          meProvider.overrideWith(
            (_) => Future.error(StateError('Sign in required')),
          ),
          publicEventPreviewProvider('private').overrideWith(
            (_) => Future.error(
              StateError('This event is not available publicly.'),
            ),
          ),
        ],
        child: const MaterialApp(home: SharedEventPage(postId: 'private')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sign in to join event'), findsNothing);
    expect(find.text('Hosted by Maya Surfer'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('past and undated events are labelled honestly', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          meProvider.overrideWith(
            (_) => Future.error(StateError('Sign in required')),
          ),
          publicEventPreviewProvider(
            'event_test',
          ).overrideWith((_) async => _event(ended: true, dated: false)),
        ],
        child: const MaterialApp(home: SharedEventPage(postId: 'event_test')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Date to be confirmed'), findsOneWidget);
    expect(find.text('This event has ended'), findsOneWidget);
    expect(find.text('Sign in to join event'), findsNothing);
  });

  testWidgets('copy button copies the canonical public link', (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          meProvider.overrideWith(
            (_) => Future.error(StateError('Sign in required')),
          ),
          publicSpotPreviewProvider(
            'spot_test',
          ).overrideWith((_) async => _spot),
        ],
        child: const MaterialApp(home: SharedSpotPage(spotId: 'spot_test')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy public link'));
    await tester.pump();
    expect(clipboard, 'https://tydes.io/#/spot/spot_test');
    expect(find.text('Public link copied.'), findsOneWidget);
  });

  for (final profileSetup in [false, true]) {
    testWidgets(
      'login returns to shared event after ${profileSetup ? 'profile completion' : 'email sign in'}',
      (tester) async {
        final repo = _Repo();
        if (profileSetup) {
          repo.me = repo.me.copyWith(
            displayName: '',
            handle: '',
            surfSkill: '',
          );
        }
        final router = GoRouter(
          initialLocation: '/login',
          routes: [
            GoRoute(
              path: '/login',
              builder: (_, _) => AuthPage(
                returnTo: '/post/event_test',
                initialProfile: profileSetup ? repo.me : null,
              ),
            ),
            GoRoute(
              path: '/post/:id',
              builder: (_, _) => const Text('Returned to original event'),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [surfRepositoryProvider.overrideWithValue(repo)],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        for (final entry
            in (profileSetup
                    ? {'Name': 'Maya Surfer', '@tag': 'mayasurfer'}
                    : {
                        'Email': 'maya@example.com',
                        'Password': 'test-password',
                      })
                .entries) {
          final field = find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == entry.key,
          );
          await tester.ensureVisible(field);
          await tester.enterText(field, entry.value);
        }
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        if (profileSetup) {
          await tester.ensureVisible(find.text('Skilled'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Skilled'));
        }
        final button = find.widgetWithText(
          FilledButton,
          profileSetup ? 'Finish profile' : 'Sign in',
        );
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('Returned to original event'), findsOneWidget);
      },
    );
  }
}
