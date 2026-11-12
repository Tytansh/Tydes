import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/app/app.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/features/auth/verification_gate_page.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/settings/settings_page.dart';
import 'package:mobile_flutter/features/social/direct_messages_page.dart';
import 'package:mobile_flutter/features/social/inbox_badges.dart';
import 'package:mobile_flutter/features/social/notifications_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';
import 'package:mobile_flutter/features/spots/spots_page.dart';

class _Session extends DemoPersistence {
  String? token = 'alice';
  @override
  Future<String?> loadAccessToken() async => token;
  @override
  Future<void> saveFavoriteSpotIds(List<String> ids) async {}
  @override
  Future<bool> clearAccessTokenIfMatches(String expected) async {
    if (token != expected) return false;
    token = null;
    return true;
  }
}

ResponseBody _body(Object value, [int status = 200]) => ResponseBody.fromString(
  jsonEncode(value),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

class _Backend implements HttpClientAdapter {
  int meReads = 0;
  Completer<ResponseBody>? pendingMe;
  Map<String, Object> user({String name = 'Alice Surfer'}) => {
    'id': 'alice',
    'email': 'alice@example.invalid',
    'display_name': name,
    'handle': 'alice',
    'bio': 'Existing profile bio',
    'surf_skill': 'intermediate',
    'home_region': 'Bali',
    'locale': 'en',
    'email_verified': true,
    'premium': false,
  };
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    if (options.path == '/users/me') {
      meReads++;
      return pendingMe?.future ?? Future.value(_body(user()));
    }
    return _body([]);
  }

  @override
  void close({bool force = false}) {}
}

class _Counts extends InboxUnreadApi {
  _Counts() : super(Dio());
  @override
  Future<InboxUnreadCounts> fetch(String accountId) async =>
      InboxUnreadCounts(accountId: accountId, messages: 2);
}

SocialNotificationModel _notification(String id) =>
    SocialNotificationModel.fromJson({
      'id': id,
      'recipient_user_id': 'alice',
      'actor_user_id': 'crew',
      'actor_name': 'Wave Crew',
      'actor_handle': 'crew',
      'type': 'like',
      'message': 'liked your post.',
      'preview': 'Existing notification $id',
      'created_at': '2026-11-12T00:00:00Z',
      'read_at': '2026-11-12T00:01:00Z',
    });

Future<ProviderContainer> _show(
  WidgetTester tester,
  _Backend backend,
  _Session session, {
  String route = '/',
  Future<List<SocialNotificationModel>> Function()? notifications,
  Future<List<JoinedEventChatSummary>> Function()? events,
}) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final dio = Dio(BaseOptions(baseUrl: 'https://not-real.invalid'))
    ..httpClientAdapter = backend;
  final container = ProviderContainer(
    overrides: [
      demoPersistenceProvider.overrideWithValue(session),
      dioProvider.overrideWithValue(dio),
      routerInitialLocationProvider.overrideWithValue(route),
      currentTabProvider.overrideWith((_) => 4),
      shellPagesProvider.overrideWithValue(const [
        Text('Existing feed'),
        SizedBox(),
        SizedBox(),
        SizedBox(),
        SettingsPage(),
      ]),
      friendsProvider.overrideWith((_) async => []),
      socialPostsProvider.overrideWith((_) async => []),
      socialProfilesProvider.overrideWith((_) async => []),
      spotsProvider.overrideWith((_) async => []),
      socialEngagementHydrationProvider.overrideWith((_) async {}),
      socialRelationshipHydrationProvider.overrideWith((_) async {}),
      socialNotificationsProvider.overrideWith(
        (_) => notifications?.call() ?? Future.value([_notification('one')]),
      ),
      joinedEventChatsProvider.overrideWith(
        (_) => events?.call() ?? Future.value([]),
      ),
      inboxUnreadApiProvider.overrideWithValue(_Counts()),
      directMessageThreadsProvider.overrideWith(
        (_) => DirectMessageThreadsNotifier.testing(const [
          DirectMessageThread(
            id: 'crew',
            profileUserId: 'crew',
            name: 'Wave Crew',
            handle: 'crew',
            initial: 'W',
            location: 'Bali',
            preview: 'Existing message',
            time: 'Now',
            unreadCount: 0,
            online: false,
            requestAccepted: true,
            messages: [],
          ),
        ]),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const SurfTravelApp(enableAlertMonitor: false),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _pull(WidgetTester tester, Finder list) async {
  final gesture = await tester.startGesture(
    tester.getTopLeft(list) + const Offset(80, 60),
  );
  for (final distance in [200.0, 200.0, 100.0]) {
    await gesture.moveBy(Offset(0, distance));
    await tester.pump();
  }
  await gesture.up();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(milliseconds: 300));
  await _drainRouting(tester);
}

Future<void> _drainRouting(WidgetTester tester) async {
  // Async redirect + retained-token checks span multiple microtask frames.
  // Do not pumpAndSettle while the deliberately held request/spinner is live.
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void _expectNoAccountLoading() {
  expect(find.byType(AccountCheckPage), findsNothing);
  expect(find.textContaining('Loading your profile'), findsNothing);
  expect(find.textContaining('Loading your account'), findsNothing);
}

void main() {
  testWidgets(
    'real router keeps Profile mounted during pull and tab switches',
    (tester) async {
      final backend = _Backend();
      final container = await _show(tester, backend, _Session());
      final hero = tester.element(find.text('Alice Surfer'));
      backend.pendingMe = Completer<ResponseBody>();
      await _pull(
        tester,
        find
            .descendant(
              of: find.byType(SettingsPage),
              matching: find.byType(ListView),
            )
            .first,
      );
      expect(backend.meReads, 2);
      expect(
        find.byKey(const ValueKey('feed-top-refresh-spinner')),
        findsOneWidget,
      );
      _expectNoAccountLoading();
      expect(tester.element(find.text('Alice Surfer')), same(hero));
      expect(container.read(inboxForegroundAccountProvider), 'alice');
      container.read(currentTabProvider.notifier).state = 0;
      await tester.pump();
      _expectNoAccountLoading();
      expect(find.text('Existing feed'), findsOneWidget);
      container.read(currentTabProvider.notifier).state = 4;
      await tester.pump();
      expect(tester.element(find.text('Alice Surfer')), same(hero));
      backend.pendingMe!.complete(_body(backend.user(name: 'Alice Updated')));
      await tester.pumpAndSettle();
      expect(find.text('Alice Updated'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('feed-top-refresh-spinner')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('routed Messages refresh keeps its search and original thread', (
    tester,
  ) async {
    final backend = _Backend();
    final pending = Completer<List<JoinedEventChatSummary>>();
    var reads = 0;
    final container = await _show(
      tester,
      backend,
      _Session(),
      route: '/messages',
      events: () => ++reads == 1 ? Future.value([]) : pending.future,
    );
    await tester.enterText(find.byType(TextField).first, 'Crew');
    await tester.pump();
    final page = tester.element(find.byType(DirectMessagesPage));
    final thread = tester.element(find.text('Existing message'));
    await _pull(
      tester,
      find
          .descendant(
            of: find.byType(DirectMessagesPage),
            matching: find.byType(ListView),
          )
          .first,
    );
    expect(backend.meReads, 1, reason: 'Inbox pull must not bootstrap account');
    backend.pendingMe = Completer<ResponseBody>();
    container.invalidate(meProvider);
    await _drainRouting(tester);
    _expectNoAccountLoading();
    expect(tester.element(find.byType(DirectMessagesPage)), same(page));
    expect(tester.element(find.text('Existing message')), same(thread));
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'Crew',
    );
    expect(container.read(inboxForegroundAccountProvider), 'alice');
    backend.pendingMe!.complete(_body(backend.user()));
    pending.complete([]);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('routed Notifications survive refresh, background and resume', (
    tester,
  ) async {
    final backend = _Backend();
    var reads = 0;
    final pending = Completer<List<SocialNotificationModel>>();
    final container = await _show(
      tester,
      backend,
      _Session(),
      route: '/notifications',
      notifications: () =>
          ++reads == 1 ? Future.value([_notification('one')]) : pending.future,
    );
    final item = tester.element(find.text('Existing notification one'));
    await _pull(tester, find.byType(ListView).first);
    backend.pendingMe = Completer<ResponseBody>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(container.read(inboxForegroundAccountProvider), 'alice');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _drainRouting(tester);
    _expectNoAccountLoading();
    expect(tester.element(find.text('Existing notification one')), same(item));
    expect(
      reads,
      2,
      reason: 'Do not clear/reload owner during background refresh',
    );
    backend.pendingMe!.complete(_body(backend.user()));
    pending.complete([_notification('one'), _notification('two')]);
    await tester.pumpAndSettle();
    expect(find.text('Existing notification two'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final blocked in [
    'different-token',
    'verification-required',
    'expired',
  ]) {
    testWidgets('retained account cannot bypass $blocked during refresh', (
      tester,
    ) async {
      final backend = _Backend();
      final session = _Session();
      final container = await _show(tester, backend, session);
      backend.pendingMe = Completer<ResponseBody>();
      if (blocked == 'different-token') session.token = 'bob';
      if (blocked == 'expired') session.token = null;
      if (blocked == 'verification-required') {
        container.read(emailVerificationRequiredTokenProvider.notifier).state =
            'alice';
      }
      container.invalidate(meProvider);
      await _drainRouting(tester);
      expect(find.text('Alice Surfer'), findsNothing);
      expect(find.byType(SettingsPage), findsNothing);
      backend.pendingMe!.complete(
        _body({
          ...backend.user(),
          if (blocked == 'different-token') ...{
            'id': 'bob',
            'email': 'bob@example.invalid',
          },
          'email_verified': false,
        }),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
