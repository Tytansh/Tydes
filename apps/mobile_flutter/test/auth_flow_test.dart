import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/auth/auth_page.dart';
import 'package:mobile_flutter/features/auth/auth_return_path.dart';
import 'package:mobile_flutter/features/core/app_scaffold.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

final _complete = DemoSeed.me.copyWith(
  id: 'currentuser',
  email: 'current@example.com',
  displayName: 'Current Surfer',
  handle: 'currentsurfer',
  surfSkill: 'intermediate',
);
final _blank = _complete.copyWith(
  id: 'newuser',
  displayName: '',
  handle: '',
  surfSkill: '',
);

class _AuthRepo extends SurfRepository {
  _AuthRepo() : super(Dio(), DemoPersistence());
  int logoutCalls = 0;
  UserProfile profile = _blank;
  @override
  Future<UserProfile> login(
    String email,
    String locale, {
    String? password,
  }) async => _complete;
  @override
  Future<SignupResult> signup({
    required String email,
    required String password,
    required String locale,
  }) async => SignupResult(
    user: _blank,
    verificationRequired: false,
    verificationSentTo: null,
    verificationHint: null,
  );
  @override
  Future<UserProfile> fetchMe() async => profile;
  @override
  Future<UserProfile> logout() async {
    logoutCalls++;
    return _blank;
  }

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
  }) async {
    return profile = _blank.copyWith(
      displayName: displayName,
      handle: handle,
      bio: bio,
      surfSkill: surfSkill,
      homeRegion: homeRegion,
    );
  }
}

void main() {
  for (final destination in <AccountDestination?, int>{
    null: 2,
    AccountDestination.feed: 0,
    AccountDestination.profile: 4,
  }.entries) {
    testWidgets('guest sign-in opens account tab ${destination.value}', (
      tester,
    ) async {
      final repo = _AuthRepo()..profile = _complete;
      final router = GoRouter(
        initialLocation: '/login',
        routes: [
          GoRoute(
            path: '/login',
            builder: (_, _) => AuthPage(
              returnTo: '/explore/events',
              accountDestination: destination.key,
            ),
          ),
          GoRoute(path: '/', builder: (_, _) => const Text('Account opened')),
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
      for (final entry in {
        'Email': 'current@example.com',
        'Password': 'test-password',
      }.entries) {
        final field = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == entry.key,
        );
        await tester.ensureVisible(field);
        await tester.enterText(field, entry.value);
      }
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      final submit = find.widgetWithText(FilledButton, 'Sign in');
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('Account opened'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      expect(container.read(currentTabProvider), destination.value);
    });
  }
  for (final width in [430.0, 1440.0]) {
    testWidgets(
      'Google and email profile completion share the signup card at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = _AuthRepo();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [surfRepositoryProvider.overrideWithValue(repo)],
            child: MaterialApp(home: AuthPage(initialProfile: _blank)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Create your profile'), findsOneWidget);
        expect(find.text('Signed in as current@example.com'), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.text('Use another account'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final name = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Name',
        );
        final handle = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '@tag',
        );
        expect(tester.widget<TextField>(name).maxLength, 32);
        expect(tester.widget<TextField>(handle).maxLength, 20);
        await tester.ensureVisible(find.text('Use another account'));
        await tester.tap(find.text('Use another account'));
        await tester.pumpAndSettle();
        expect(repo.logoutCalls, 1);
        expect(find.text('Welcome back'), findsOneWidget);
      },
    );
  }

  testWidgets('email signup uses inline profile setup, not a bottom sheet', (
    tester,
  ) async {
    final repo = _AuthRepo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [surfRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: AuthPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign up'));
    await tester.pumpAndSettle();
    for (final entry in {
      'Email': 'current@example.com',
      'Password': 'test-password',
      'Confirm password': 'test-password',
    }.entries) {
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == entry.key,
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, entry.value);
    }
    final submit = find.widgetWithText(FilledButton, 'Create account');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('Create your profile'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets(
    'retained blank profile waits for new account without logging it out',
    (tester) async {
      final pending = Completer<UserProfile>();
      final repo = _AuthRepo();
      var reads = 0;
      final container = ProviderContainer(
        overrides: [
          surfRepositoryProvider.overrideWithValue(repo),
          meProvider.overrideWith(
            (_) => ++reads == 1 ? Future.value(_blank) : pending.future,
          ),
          shellPagesProvider.overrideWithValue(const [
            Text('Signed in feed'),
            SizedBox(),
            SizedBox(),
            SizedBox(),
            SizedBox(),
          ]),
          socialRelationshipHydrationProvider.overrideWith((_) async {}),
        ],
      );
      addTearDown(container.dispose);
      await container.read(meProvider.future);
      container.invalidate(meProvider);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const AppScaffold()),
          GoRoute(
            path: '/login',
            builder: (_, _) => const Text('Wrong login redirect'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      expect(find.text('Loading your account...'), findsOneWidget);
      expect(repo.logoutCalls, 0);
      pending.complete(_complete);
      await tester.pumpAndSettle();
      expect(find.text('Signed in feed'), findsOneWidget);
      expect(find.text('Wrong login redirect'), findsNothing);
      expect(repo.logoutCalls, 0);
    },
  );

  testWidgets('first login waits for the new profile before leaving login', (
    tester,
  ) async {
    final pending = Completer<UserProfile>();
    final repo = _AuthRepo();
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        surfRepositoryProvider.overrideWithValue(repo),
        meProvider.overrideWith(
          (_) => ++reads == 1 ? Future.value(_blank) : pending.future,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(meProvider.future);
    final router = GoRouter(
      initialLocation: '/login',
      routes: [
        GoRoute(path: '/login', builder: (_, _) => const AuthPage()),
        GoRoute(
          path: '/',
          builder: (_, _) => const Text('Login completed once'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    for (final entry in {
      'Email': 'current@example.com',
      'Password': 'test-password',
    }.entries) {
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == entry.key,
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, entry.value);
    }
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(find.text('Login completed once'), findsNothing);
    pending.complete(_complete);
    await tester.pumpAndSettle();
    expect(find.text('Login completed once'), findsOneWidget);
    expect(repo.logoutCalls, 0);
  });
}
