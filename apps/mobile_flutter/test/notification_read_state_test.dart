import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/features/social/inbox_badges.dart';
import 'package:mobile_flutter/features/social/notification_read_state.dart';
import 'package:mobile_flutter/features/social/notifications_page.dart';

class _Transport implements HttpClientAdapter {
  _Transport(this.handler);
  final Future<ResponseBody> Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) => handler(options);
  @override
  void close({bool force = false}) {}
}

NotificationReadApi _api(
  Future<ResponseBody> Function(RequestOptions) handler,
) => NotificationReadApi(
  Dio(BaseOptions(baseUrl: 'https://test.invalid'))
    ..httpClientAdapter = _Transport(handler),
);

ResponseBody _response(Object body, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

SocialNotificationModel _item(String id, String owner, {String? readAt}) =>
    SocialNotificationModel.fromJson({
      'id': id,
      'recipient_user_id': owner,
      'actor_user_id': 'actor',
      'actor_name': 'Surfer',
      'type': 'like',
      'message': 'liked your post.',
      'preview': 'Notification $id for $owner',
      'created_at': '2026-11-12T00:00:00Z',
      'read_at': readAt,
    });

class _ControlledApi extends NotificationReadApi {
  _ControlledApi() : super(Dio());
  final requests = <(String, Set<String>)>[];
  Completer<NotificationReadReceipt>? pending;
  bool fail = false;
  @override
  Future<NotificationReadReceipt> markRead({
    required String accountId,
    required Set<String> notificationIds,
  }) async {
    requests.add((accountId, Set.of(notificationIds)));
    if (pending != null && accountId == 'first') return pending!.future;
    if (fail) throw StateError('Offline');
    return NotificationReadReceipt(
      accountId: accountId,
      readIds: notificationIds,
      unreadCount: 0,
    );
  }
}

Future<ProviderContainer> _show(
  WidgetTester tester,
  _ControlledApi api,
  List<SocialNotificationModel> Function(String? owner) notifications,
) async {
  final container = ProviderContainer(
    overrides: [
      inboxForegroundAccountProvider.overrideWith((_) => 'first'),
      notificationReadApiProvider.overrideWithValue(api),
      socialNotificationsProvider.overrideWith(
        (ref) async => notifications(ref.watch(inboxForegroundAccountProvider)),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SocialNotificationsPage()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  test(
    'read service validates owner, concrete IDs and actual nonnegative count',
    () async {
      final api = _api((options) async {
        expect(options.method, 'POST');
        expect(options.path, '/social/notifications/read');
        expect(
          (options.data as Map)['notification_ids'],
          unorderedEquals(['one', 'two']),
        );
        return _response({
          'user_id': 'first',
          'read_ids': ['one', 'two'],
          'unread_count': 12,
        });
      });
      final receipt = await api.markRead(
        accountId: 'first',
        notificationIds: {'one', 'two'},
      );
      expect(receipt.unreadCount, 12);
      expect(receipt.readIds, {'one', 'two'});
    },
  );

  for (final body in [
    {
      'user_id': 'other',
      'read_ids': ['one'],
      'unread_count': 0,
    },
    {
      'user_id': 'first',
      'read_ids': ['foreign'],
      'unread_count': 0,
    },
    {
      'user_id': 'first',
      'read_ids': [1],
      'unread_count': 0,
    },
    {
      'user_id': 'first',
      'read_ids': ['one'],
      'unread_count': -1,
    },
    {
      'user_id': 'first',
      'read_ids': ['one'],
      'unread_count': '0',
    },
  ]) {
    test('unconfirmed notification receipt is rejected: $body', () async {
      await expectLater(
        _api(
          (_) async => _response(body),
        ).markRead(accountId: 'first', notificationIds: {'one'}),
        throwsStateError,
      );
    });
  }

  for (final status in [401, 403, 429, 503]) {
    test('notification read $status never fabricates a success', () async {
      await expectLater(
        _api(
          (_) async => _response({'detail': 'Rejected'}, status),
        ).markRead(accountId: 'first', notificationIds: {'one'}),
        throwsA(isA<DioException>()),
      );
    });
  }

  testWidgets('opening marks only owned loaded IDs after confirmation', (
    tester,
  ) async {
    final api = _ControlledApi()
      ..pending = Completer<NotificationReadReceipt>();
    final container = await _show(
      tester,
      api,
      (_) => [
        _item('one', 'first'),
        _item('two', 'first'),
        _item('foreign', 'other'),
      ],
    );
    expect(api.requests.length, 1);
    expect(api.requests.single.$1, 'first');
    expect(api.requests.single.$2, {'one', 'two'});
    expect(find.text('Notification foreign for other'), findsNothing);
    expect(container.read(inboxCountsRefreshKeyProvider), 0);
    api.pending!.complete(
      const NotificationReadReceipt(
        accountId: 'first',
        readIds: {'one', 'two'},
        unreadCount: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(inboxCountsRefreshKeyProvider), 1);
    expect(find.text('Notification one for first'), findsOneWidget);
    expect(api.requests.length, 1);
  });

  testWidgets('failed read keeps content and count, Retry waits for server', (
    tester,
  ) async {
    final api = _ControlledApi()..fail = true;
    final container = await _show(tester, api, (_) => [_item('one', 'first')]);
    expect(find.text('Notification one for first'), findsOneWidget);
    expect(
      find.text('Could not update notification read status.'),
      findsOneWidget,
    );
    expect(api.requests.length, 1);
    expect(container.read(inboxCountsRefreshKeyProvider), 0);
    api.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(api.requests.length, 2);
    expect(container.read(inboxCountsRefreshKeyProvider), 1);
    expect(
      find.text('Could not update notification read status.'),
      findsNothing,
    );
  });

  testWidgets(
    'old account results and late receipt cannot leak or clear new badge',
    (tester) async {
      final api = _ControlledApi()
        ..pending = Completer<NotificationReadReceipt>();
      final container = await _show(
        tester,
        api,
        (_) => [_item('one', 'first')],
      );
      expect(find.text('Notification one for first'), findsOneWidget);
      container.read(inboxForegroundAccountProvider.notifier).state = 'second';
      await tester.pumpAndSettle();
      expect(find.text('Notification one for first'), findsNothing);
      expect(find.text('No notifications yet.'), findsOneWidget);
      api.pending!.complete(
        const NotificationReadReceipt(
          accountId: 'first',
          readIds: {'one'},
          unreadCount: 0,
        ),
      );
      await tester.pumpAndSettle();
      expect(container.read(inboxCountsRefreshKeyProvider), 0);
      expect(api.requests.length, 1);
    },
  );

  testWidgets('already read notifications do not send redundant receipts', (
    tester,
  ) async {
    final api = _ControlledApi();
    await _show(
      tester,
      api,
      (_) => [_item('one', 'first', readAt: '2026-11-12T01:00:00Z')],
    );
    expect(api.requests, isEmpty);
    expect(find.text('Notification one for first'), findsOneWidget);
  });

  testWidgets('a covered notifications page does not mark unseen loaded rows', (
    tester,
  ) async {
    final api = _ControlledApi();
    final pending = Completer<List<SocialNotificationModel>>();
    final container = ProviderContainer(
      overrides: [
        inboxForegroundAccountProvider.overrideWith((_) => 'first'),
        notificationReadApiProvider.overrideWithValue(api),
        socialNotificationsProvider.overrideWith((_) => pending.future),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SocialNotificationsPage()),
      ),
    );
    await tester.pump();
    final navigator = Navigator.of(
      tester.element(find.byType(SocialNotificationsPage)),
    );
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Covering page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    pending.complete([_item('one', 'first')]);
    await tester.pumpAndSettle();
    expect(find.text('Covering page'), findsOneWidget);
    expect(api.requests, isEmpty);
    expect(container.read(inboxCountsRefreshKeyProvider), 0);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('Notification one for first'), findsOneWidget);
    expect(api.requests.length, 1);
    expect(container.read(inboxCountsRefreshKeyProvider), 1);
  });
}
