import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_flutter/app/app.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/inbox_badges.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

class _Transport implements HttpClientAdapter {
  _Transport(this.reply);
  final Map<String, dynamic> Function(RequestOptions) reply;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(reply(options)),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
  @override
  void close({bool force = false}) {}
}

class _FakeCounts extends InboxUnreadApi {
  _FakeCounts(this.reply) : super(Dio());
  final Future<InboxUnreadCounts> Function(String) reply;
  @override
  Future<InboxUnreadCounts> fetch(String accountId) => reply(accountId);
}

void main() {
  for (final width in [320.0, 390.0, 1440.0]) {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      testWidgets(
        'feed header fits unread counts at $width ${theme.brightness}',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                meProvider.overrideWith((_) async => DemoSeed.me),
                inboxUnreadCountsProvider.overrideWith(
                  (_) async => InboxUnreadCounts(
                    accountId: DemoSeed.me.id,
                    messages: 12,
                    notifications: 2,
                  ),
                ),
                travelFeedPostsProvider.overrideWith((_) async => []),
                travelFeedSpotsProvider.overrideWith((_) async => []),
                socialEngagementHydrationProvider.overrideWith((_) async {}),
                socialRelationshipHydrationProvider.overrideWith((_) async {}),
              ],
              child: MaterialApp(
                theme: theme,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: const HomePage(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byTooltip('Messages'), findsOneWidget);
          expect(find.byTooltip('Notifications'), findsOneWidget);
          expect(find.text('12'), findsOneWidget);
          expect(find.text('2'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  test('counts retain exact unread messages and notification totals', () async {
    final paths = <String>[];
    final dio = Dio()
      ..httpClientAdapter = _Transport((options) {
        paths.add(options.path);
        return {
          'user_id': 'owner',
          'unread_count': options.path.startsWith('/messages/') ? 12 : 2,
        };
      });
    final counts = await InboxUnreadApi(dio).fetch('owner');
    expect(counts.messages, 12);
    expect(counts.notifications, 2);
    expect(counts.total, 14);
    expect(paths.toSet(), {
      '/messages/unread-count',
      '/social/notifications/unread-count',
    });
  });

  for (final bad in [
    {'user_id': 'someone-else', 'unread_count': 12},
    {'user_id': 'owner', 'unread_count': -1},
    {'user_id': 'owner', 'unread_count': '12'},
    {'unread_count': 12},
  ]) {
    test('unconfirmed counts never become badges: $bad', () async {
      final dio = Dio()..httpClientAdapter = _Transport((_) => bad);
      await expectLater(InboxUnreadApi(dio).fetch('owner'), throwsStateError);
    });
  }

  test(
    'late old-account response cannot replace the new account counts',
    () async {
      final old = Completer<InboxUnreadCounts>();
      final container = ProviderContainer(
        overrides: [
          inboxForegroundAccountProvider.overrideWith((_) => 'old'),
          inboxUnreadApiProvider.overrideWithValue(
            _FakeCounts(
              (id) => id == 'old'
                  ? old.future
                  : Future.value(InboxUnreadCounts(accountId: id, messages: 2)),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(inboxUnreadCountsProvider, (_, _) {});
      addTearDown(sub.close);
      final oldRequest = container.read(inboxUnreadCountsProvider.future);
      container.read(inboxForegroundAccountProvider.notifier).state = 'new';
      expect(
        (await container.read(inboxUnreadCountsProvider.future)).accountId,
        'new',
      );
      old.complete(const InboxUnreadCounts(accountId: 'old', messages: 12));
      await oldRequest;
      expect(
        container.read(inboxUnreadCountsProvider).valueOrNull?.messages,
        2,
      );
      container.read(inboxForegroundAccountProvider.notifier).state = null;
      expect((await container.read(inboxUnreadCountsProvider.future)).total, 0);
    },
  );

  for (final theme in [AppTheme.light(), AppTheme.dark()]) {
    for (final count in [0, 1, 2, 12, 1200]) {
      testWidgets(
        'badge displays $count without clipping in ${theme.brightness}',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: Center(
                  child: InboxUnreadBadge(
                    count: count,
                    child: const Icon(Icons.mail_outline),
                  ),
                ),
              ),
            ),
          );
          expect(
            find.text('$count'),
            count == 0 ? findsNothing : findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (count > 0) {
            final label = tester.getRect(find.text('$count'));
            expect(label.width, greaterThan(0));
          }
        },
      );
    }
  }

  testWidgets('foreground signed-in polling stops while hidden or signed out', (
    tester,
  ) async {
    var calls = 0;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: _CountView()),
        ),
        GoRoute(
          path: '/login',
          builder: (_, _) => const Scaffold(body: Text('Login')),
        ),
      ],
    );
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        appRouterProvider.overrideWithValue(router),
        meProvider.overrideWith((_) async => DemoSeed.me),
        inboxUnreadApiProvider.overrideWithValue(
          _FakeCounts((id) async {
            calls++;
            return InboxUnreadCounts(accountId: id, messages: 12);
          }),
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
    expect(calls, 1);
    expect(find.text('12'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(calls, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    await tester.pump(const Duration(seconds: 61));
    expect(calls, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 3);
    router.go('/login');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 61));
    expect(calls, 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _CountView extends ConsumerWidget {
  const _CountView();
  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      Text('${watchInboxCounts(ref, DemoSeed.me.id).messages}');
}
