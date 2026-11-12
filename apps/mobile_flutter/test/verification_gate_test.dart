import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/app/app.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/theme/theme_preference.dart';
import 'package:mobile_flutter/features/auth/auth_page.dart';
import 'package:mobile_flutter/features/auth/auth_return_path.dart';
import 'package:mobile_flutter/features/auth/google_sign_in_button.dart';
import 'package:mobile_flutter/features/auth/verification_gate_page.dart';
import 'package:mobile_flutter/features/core/app_scaffold.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/direct_messages_page.dart';
import 'package:mobile_flutter/features/social/event_chat_page.dart';
import 'package:mobile_flutter/features/social/notifications_page.dart';
import 'package:mobile_flutter/features/social/public_profile_page.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';
import 'package:mobile_flutter/features/paywall/paywall_page.dart';
import 'package:mobile_flutter/features/admin/admin_users_page.dart';

class _Sessions extends DemoPersistence {
  String? token = 'alice';
  @override
  Future<String?> loadAccessToken() async => token;
  @override
  Future<void> saveAccessToken(String value) async => token = value;
  @override
  Future<bool> clearAccessTokenIfMatches(String expected) async {
    if (token != expected) return false;
    token = null;
    return true;
  }

  @override
  Future<void> saveFavoriteSpotIds(List<String> ids) async {}
}

ResponseBody _body(Object body, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

class _Backend implements HttpClientAdapter {
  final calls = <RequestOptions>[];
  bool verified = false;
  bool incomplete = false;
  bool offline = false;
  Completer<ResponseBody>? pendingMe;
  Completer<ResponseBody>? pendingConfirm;

  Map<String, Object> user([String owner = 'alice']) => {
    'id': owner,
    'email': '$owner@example.com',
    'display_name': incomplete ? '' : 'Alice Surfer',
    'handle': incomplete ? '' : owner,
    'bio': '',
    'surf_skill': incomplete ? '' : 'intermediate',
    'home_region': '',
    'locale': 'en',
    'email_verified': verified,
    'premium': false,
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    final owner =
        (options.headers['Authorization'] as String?)?.replaceFirst(
          'Bearer ',
          '',
        ) ??
        'alice';
    switch (options.path) {
      case '/users/me':
        if (pendingMe != null) return pendingMe!.future;
        if (offline) return _body({'detail': 'Temporarily unavailable'}, 503);
        return _body(user(owner));
      case '/auth/login':
        return _body({'access_token': 'alice', 'user': user()});
      case '/auth/google':
        verified = true;
        return _body({
          'session': {'access_token': 'alice', 'user': user()},
          'verification_required': false,
        });
      case '/auth/signup':
        return _body({
          'session': {'access_token': 'alice', 'user': user()},
          'verification_required': true,
          'verification_sent_to': 'alice@example.com',
        });
      case '/auth/email-verification/request':
        return _body({
          'sent': !verified,
          'already_verified': verified,
          if (!verified) 'verification_sent_to': '$owner@example.com',
        });
      case '/auth/email-verification/confirm':
        if (pendingConfirm != null) return pendingConfirm!.future;
        verified = true;
        return _body(user(owner));
      case '/auth/logout':
      case '/auth/account':
        return _body(user(owner));
      default:
        return _body({'detail': 'Unexpected private request'}, 500);
    }
  }

  @override
  void close({bool force = false}) {}
}

Future<ProviderContainer> _show(
  WidgetTester tester,
  _Backend backend,
  _Sessions sessions, {
  String route = '/',
  ThemeMode mode = ThemeMode.light,
  double textScale = 1,
}) async {
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final dio = Dio(BaseOptions(baseUrl: 'https://not-real.invalid'))
    ..httpClientAdapter = backend;
  final container = ProviderContainer(
    overrides: [
      demoPersistenceProvider.overrideWithValue(sessions),
      dioProvider.overrideWithValue(dio),
      routerInitialLocationProvider.overrideWithValue(route),
      initialThemeModeProvider.overrideWithValue(mode),
      shellPagesProvider.overrideWithValue(
        List.filled(5, const Text('Private account shell')),
      ),
      socialRelationshipHydrationProvider.overrideWith((_) async {}),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: const SurfTravelApp(
          enableAlertMonitor: false,
          enableInboxPolling: false,
        ),
      ),
    ),
  );
  return container;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void _expectNoPrivatePage() {
  for (final type in [
    AppScaffold,
    DirectMessagesPage,
    EventChatPage,
    SocialNotificationsPage,
    PublicProfilePage,
    PaywallPage,
    AdminUsersPage,
  ]) {
    expect(find.byType(type), findsNothing);
  }
}

void main() {
  for (final route in [
    '/',
    '/messages?thread=thread_123',
    '/notifications',
    '/profile/alice?post=post_123',
    '/paywall',
    '/admin',
    '/spots-map',
    '/people-search',
    '/event/post_123/chat',
  ]) {
    testWidgets(
      'unverified restored session gates $route before any private mount',
      (tester) async {
        final backend = _Backend();
        final sessions = _Sessions();
        final container = await _show(tester, backend, sessions, route: route);
        await tester.pumpAndSettle();
        expect(find.byType(VerificationGatePage), findsOneWidget);
        _expectNoPrivatePage();
        expect(backend.calls.map((call) => call.path), ['/users/me']);
        expect(sessions.token, 'alice');
        expect(
          container
              .read(appRouterProvider)
              .routeInformationProvider
              .value
              .uri
              .queryParameters['next'],
          route,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('restoration and offline retry never mount a private page', (
    tester,
  ) async {
    final backend = _Backend()..pendingMe = Completer<ResponseBody>();
    final container = await _show(
      tester,
      backend,
      _Sessions(),
      route: '/messages',
    );
    await tester.pump();
    expect(find.byType(AccountCheckPage), findsOneWidget);
    _expectNoPrivatePage();
    for (var i = 0; i < 10 && backend.calls.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(backend.calls, hasLength(1));
    backend.pendingMe!.complete(_body({}, 503));
    backend.pendingMe = null;
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    _expectNoPrivatePage();
    await _tap(tester, find.text('Retry'));
    expect(find.byType(VerificationGatePage), findsOneWidget);
    expect(
      container
          .read(appRouterProvider)
          .routeInformationProvider
          .value
          .uri
          .queryParameters['next'],
      '/messages',
    );
    expect(backend.calls.every((call) => call.path == '/users/me'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'explicit code request and confirmation reopen a fresh verified account',
    (tester) async {
      final backend = _Backend();
      final container = await _show(tester, backend, _Sessions());
      await tester.pumpAndSettle();
      expect(backend.calls.length, 1);
      await _tap(tester, find.text('Send code'));
      expect(
        backend.calls.where((call) => call.path.endsWith('/request')).length,
        1,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('email-verification-code')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('email-verification-code')),
        '123456',
      );
      tester.testTextInput.hide();
      await _tap(tester, find.widgetWithText(FilledButton, 'Verify email'));
      expect(find.byType(AppScaffold), findsOneWidget);
      expect(container.read(meProvider).requireValue.emailVerified, isTrue);
      expect(
        backend.calls
            .where((call) => call.path.endsWith('/confirm'))
            .single
            .data,
        {'code': '123456'},
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'already-verified refresh uses current user proof and sends no email',
    (tester) async {
      final backend = _Backend();
      await _show(tester, backend, _Sessions());
      await tester.pumpAndSettle();
      backend.verified = true;
      await _tap(tester, find.text('I already verified my email'));
      expect(find.byType(AppScaffold), findsOneWidget);
      expect(backend.calls.every((call) => call.path == '/users/me'), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('verification resumes the intended private deep link', (
    tester,
  ) async {
    final backend = _Backend();
    final container = await _show(
      tester,
      backend,
      _Sessions(),
      route: '/notifications',
    );
    await tester.pumpAndSettle();
    backend.verified = true;
    await _tap(tester, find.text('I already verified my email'));
    expect(find.byType(SocialNotificationsPage), findsOneWidget);
    expect(
      container.read(appRouterProvider).routeInformationProvider.value.uri.path,
      '/notifications',
    );
    expect(backend.calls.every((call) => call.path == '/users/me'), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a verification-required latch closes a cached verified private shell',
    (tester) async {
      final backend = _Backend()..verified = true;
      final sessions = _Sessions();
      final container = await _show(tester, backend, sessions);
      await tester.pumpAndSettle();
      expect(find.byType(AppScaffold), findsOneWidget);
      // Simulate the current-token 403 latch before /users/me has refreshed.
      container.read(emailVerificationRequiredTokenProvider.notifier).state =
          'alice';
      await tester.pumpAndSettle();
      expect(find.byType(VerificationGatePage), findsOneWidget);
      _expectNoPrivatePage();
      expect(sessions.token, 'alice');
      expect(
        backend.calls.where((call) => call.path.endsWith('/request')),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'late code confirmation cannot verify or navigate a switched account',
    (tester) async {
      final backend = _Backend();
      final sessions = _Sessions();
      final container = await _show(tester, backend, sessions);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('email-verification-code')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('email-verification-code')),
        '123456',
      );
      tester.testTextInput.hide();
      backend.pendingConfirm = Completer<ResponseBody>();
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Verify email'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Verify email'));
      for (
        var i = 0;
        i < 10 && !backend.calls.any((call) => call.path.endsWith('/confirm'));
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(
        backend.calls.any((call) => call.path.endsWith('/confirm')),
        isTrue,
      );
      sessions.token = 'bob';
      container.invalidate(meProvider);
      await tester.pumpAndSettle();
      backend.pendingConfirm!.complete(
        _body({...backend.user('alice'), 'email_verified': true}),
      );
      await tester.pumpAndSettle();
      expect(find.byType(VerificationGatePage), findsOneWidget);
      expect(find.text('bob@example.com'), findsOneWidget);
      expect(container.read(meProvider).requireValue.id, 'bob');
      expect(container.read(meProvider).requireValue.emailVerified, isFalse);
      expect(sessions.token, 'bob');
      _expectNoPrivatePage();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'sign out clears token; reload remains unable to open private route',
    (tester) async {
      final backend = _Backend();
      final sessions = _Sessions();
      final container = await _show(
        tester,
        backend,
        sessions,
        route: '/messages',
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Sign out / use another account'));
      expect(sessions.token, isNull);
      expect(find.byType(AuthPage), findsOneWidget);
      container.read(appRouterProvider).go('/admin');
      await tester.pumpAndSettle();
      expect(find.byType(AuthPage), findsOneWidget);
      _expectNoPrivatePage();
      expect(
        backend.calls.where((call) => call.path == '/auth/account'),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'delete account requires confirmation and cancel never calls delete',
    (tester) async {
      final backend = _Backend();
      await _show(tester, backend, _Sessions());
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Delete account'));
      expect(find.text('Delete account?'), findsOneWidget);
      await _tap(tester, find.text('Cancel'));
      expect(
        backend.calls.where((call) => call.path == '/auth/account'),
        isEmpty,
      );
      _expectNoPrivatePage();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final google in [false, true]) {
    testWidgets(
      '${google ? 'verified Google' : 'unverified email'} sign-in routes using fresh verification status',
      (tester) async {
        final backend = _Backend();
        final container = await _show(
          tester,
          backend,
          _Sessions()..token = null,
          route: '/login',
        );
        await tester.pumpAndSettle();
        if (google) {
          final button = tester.widget<GoogleSignInButton>(
            find.byType(GoogleSignInButton),
          );
          final completing = button.onCredential(
            'fake-test-credential',
            'fake-test-challenge',
            'fake-test-verifier',
          );
          await tester.pumpAndSettle();
          await completing;
          expect(find.byType(AppScaffold), findsOneWidget);
        } else {
          for (final entry in {
            'Email': 'alice@example.com',
            'Password': 'test-password',
          }.entries) {
            final field = find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.labelText == entry.key,
            );
            await tester.ensureVisible(field);
            await tester.enterText(field, entry.value);
          }
          tester.testTextInput.hide();
          await _tap(tester, find.widgetWithText(FilledButton, 'Sign in'));
          expect(find.byType(VerificationGatePage), findsOneWidget);
          _expectNoPrivatePage();
        }
        expect(container.read(meProvider).requireValue.emailVerified, google);
        expect(
          backend.calls.where((call) => call.path.endsWith('/request')),
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'signup preserves already-delivered code without duplicate dispatch',
    (tester) async {
      final backend = _Backend()..incomplete = true;
      await _show(tester, backend, _Sessions()..token = null, route: '/login');
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Sign up'));
      for (final entry in {
        'Email': 'alice@example.com',
        'Password': 'test-password',
        'Confirm password': 'test-password',
      }.entries) {
        final field = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == entry.key,
        );
        await tester.ensureVisible(field);
        await tester.enterText(field, entry.value);
      }
      tester.testTextInput.hide();
      await _tap(tester, find.widgetWithText(FilledButton, 'Create account'));
      expect(find.byType(VerificationGatePage), findsOneWidget);
      expect(find.text('Resend code'), findsOneWidget);
      expect(find.text('Create your profile'), findsNothing);
      expect(
        backend.calls.where((call) => call.path.endsWith('/request')),
        isEmpty,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('email-verification-code')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('email-verification-code')),
        '123456',
      );
      tester.testTextInput.hide();
      await _tap(tester, find.widgetWithText(FilledButton, 'Verify email'));
      expect(find.text('Create your profile'), findsOneWidget);
      expect(
        backend.calls.where((call) => call.path.endsWith('/request')),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final width in [320.0, 390.0, 1440.0]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets(
        'verification is scrollable and overflow-free at $width $mode with large text',
        (tester) async {
          tester.view.physicalSize = Size(width, 960);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final backend = _Backend();
          await _show(tester, backend, _Sessions(), mode: mode, textScale: 2);
          await tester.pumpAndSettle();
          expect(
            MediaQuery.textScalerOf(
              tester.element(find.byType(TextField)),
            ).scale(10),
            20,
          );
          await tester.ensureVisible(find.text('Delete account'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(backend.calls.map((call) => call.path), ['/users/me']);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  test(
    'return destinations retain known private links and reject external or traversal paths',
    () {
      for (final path in [
        '/messages?thread=thread_123',
        '/profile/alice?post=post_123',
        '/event/post_123/chat',
        '/admin',
      ]) {
        expect(safeAuthReturnPath(path), path);
      }
      for (final path in [
        'https://example.com',
        '//example.com',
        '/login',
        '/verify-email',
        '/post/../admin',
        '/post/%2e%2e/admin',
      ]) {
        expect(safeAuthReturnPath(path), '/');
      }
    },
  );
}
