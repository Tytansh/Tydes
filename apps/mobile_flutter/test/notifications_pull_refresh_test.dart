import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/notifications_page.dart';

final _spinner = find.byKey(const ValueKey('feed-top-refresh-spinner'));

SocialNotificationModel _item(String id, String preview) =>
    SocialNotificationModel.fromJson({
      'id': id,
      'recipient_user_id': 'viewer',
      'actor_user_id': 'surfer',
      'actor_name': 'Wave Crew',
      'actor_handle': 'crew',
      'type': 'like',
      'message': 'liked your post.',
      'preview': preview,
      'created_at': '2026-11-12T00:00:00Z',
    });

Future<ProviderContainer> _show(
  WidgetTester tester,
  Future<List<SocialNotificationModel>> Function() read, {
  bool dark = false,
  double width = 390,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final container = ProviderContainer(
    overrides: [
      socialNotificationsProvider.overrideWith((_) => read()),
      meProvider.overrideWith(
        (_) => throw StateError('No account refresh allowed'),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        home: const SocialNotificationsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _pull(WidgetTester tester) async {
  final list = find.byType(ListView).first;
  final gesture = await tester.startGesture(
    tester.getTopLeft(list) + const Offset(100, 45),
  );
  for (final dy in [200.0, 200.0, 100.0]) {
    await gesture.moveBy(Offset(0, dy));
    await tester.pump();
  }
  await gesture.up();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _wheel(WidgetTester tester, Offset delta) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getCenter(find.byType(ListView).first),
      scrollDelta: delta,
    ),
  );
  await tester.pump();
}

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'touch refresh preserves notifications and top spinner in ${dark ? 'dark' : 'light'} mode',
      (tester) async {
        var reads = 0;
        final pending = Completer<List<SocialNotificationModel>>();
        final existing = _item('existing', 'Existing notification');
        await _show(
          tester,
          () => ++reads == 1 ? Future.value([existing]) : pending.future,
          dark: dark,
        );
        final original = tester.element(find.text('Existing notification'));
        await _pull(tester);
        expect(reads, 2);
        expect(_spinner, findsOneWidget);
        expect(
          tester.element(find.text('Existing notification')),
          same(original),
        );
        expect(find.text('Loading your account...'), findsNothing);
        final spinnerRect = tester.getRect(_spinner);
        expect(
          spinnerRect.bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(ListView)).top),
        );
        pending.complete([existing, _item('new', 'New notification')]);
        await tester.pumpAndSettle();
        expect(find.text('New notification'), findsOneWidget);
        expect(find.text('Existing notification'), findsOneWidget);
        expect(_spinner, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'desktop refresh ignores taps and horizontal input and runs once',
    (tester) async {
      var reads = 0;
      final pending = Completer<List<SocialNotificationModel>>();
      await _show(
        tester,
        () => ++reads == 1
            ? Future.value([_item('existing', 'Existing notification')])
            : pending.future,
        width: 1280,
      );
      final point = tester.getCenter(find.byType(ListView));
      for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
        final click = await tester.startGesture(point, kind: kind);
        await click.up();
        await tester.pump();
      }
      await _wheel(tester, const Offset(-200, 0));
      expect(reads, 1);
      expect(_spinner, findsNothing);
      await _wheel(tester, const Offset(0, -40));
      expect(reads, 1);
      await _wheel(tester, const Offset(0, -100));
      await tester.pump(const Duration(seconds: 1));
      expect(reads, 2);
      expect(_spinner, findsOneWidget);
      expect(find.text('Existing notification'), findsOneWidget);
      await _wheel(tester, const Offset(0, -300));
      expect(reads, 2);
      await _wheel(tester, const Offset(0, 80));
      expect(_spinner, findsNothing);
      expect(find.text('Existing notification'), findsOneWidget);
      pending.complete([]);
      await tester.pumpAndSettle();
      expect(find.text('No notifications yet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty notifications still support pull refresh', (tester) async {
    var reads = 0;
    final pending = Completer<List<SocialNotificationModel>>();
    await _show(tester, () => ++reads == 1 ? Future.value([]) : pending.future);
    await _pull(tester);
    expect(reads, 2);
    expect(_spinner, findsOneWidget);
    expect(find.text('No notifications yet.'), findsOneWidget);
    pending.complete([_item('new', 'New notification')]);
    await tester.pumpAndSettle();
    expect(find.text('New notification'), findsOneWidget);
  });

  testWidgets('failed refresh keeps the old list and supports another pull', (
    tester,
  ) async {
    var reads = 0;
    final pending = Completer<List<SocialNotificationModel>>();
    final existing = _item('existing', 'Existing notification');
    await _show(tester, () {
      reads++;
      if (reads == 1) return Future.value([existing]);
      if (reads == 2) return pending.future;
      return Future.value([existing, _item('new', 'New notification')]);
    });
    final original = tester.element(find.text('Existing notification'));
    await _pull(tester);
    pending.completeError(StateError('Offline'));
    await tester.pumpAndSettle();
    expect(tester.element(find.text('Existing notification')), same(original));
    expect(find.text('Could not refresh. Try again.'), findsOneWidget);
    expect(find.text('Could not load notifications.'), findsNothing);
    expect(_spinner, findsNothing);
    await _pull(tester);
    await tester.pumpAndSettle();
    expect(reads, 3);
    expect(find.text('New notification'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('initial error remains scrollable for a successful retry', (
    tester,
  ) async {
    var reads = 0;
    await _show(tester, () {
      if (++reads == 1) return Future.error(StateError('Offline'));
      return Future.value([_item('new', 'New notification')]);
    });
    expect(find.text('Could not load notifications.'), findsOneWidget);
    await _pull(tester);
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('New notification'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
