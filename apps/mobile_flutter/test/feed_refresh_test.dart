import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/widgets/feed_refresh_indicator.dart';
import 'package:mobile_flutter/features/core/app_scaffold.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

void main() {
  testWidgets('pull refresh keeps the content mounted under its spinner', (
    tester,
  ) async {
    final pending = Completer<void>();
    var refreshes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeedRefreshIndicator(
            onRefresh: () {
              refreshes++;
              return pending.future;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [Text('Existing post')],
            ),
          ),
        ),
      ),
    );
    final original = tester.element(find.text('Existing post'));
    final pull = await tester.startGesture(
      tester.getTopLeft(find.byType(ListView)) + const Offset(100, 50),
    );
    await pull.moveBy(const Offset(0, 200));
    await tester.pump();
    await pull.moveBy(const Offset(0, 200));
    await tester.pump();
    await pull.moveBy(const Offset(0, 100));
    await tester.pump();
    await pull.up();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(refreshes, 1);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(tester.element(find.text('Existing post')), same(original));
    pending.complete();
    await tester.pumpAndSettle();
    expect(tester.element(find.text('Existing post')), same(original));
  });

  testWidgets(
    'desktop overscroll shows one spinner and ignores horizontal input',
    (tester) async {
      final pending = Completer<void>();
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FeedRefreshIndicator(
              onRefresh: () {
                refreshes++;
                return pending.future;
              },
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [Text('Existing video')],
              ),
            ),
          ),
        ),
      );
      final position = tester.getCenter(find.byType(ListView));
      Future<void> wheel(Offset delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(position: position, scrollDelta: delta),
        );
        await tester.pump();
      }

      await wheel(const Offset(-200, 0));
      expect(refreshes, 0);
      await wheel(const Offset(0, -40));
      expect(refreshes, 0);
      await wheel(const Offset(0, -100));
      await tester.pump(const Duration(seconds: 1));
      expect(refreshes, 1);
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      expect(find.text('Existing video'), findsOneWidget);
      await wheel(const Offset(0, -300));
      expect(refreshes, 1);
      pending.complete();
      await tester.pumpAndSettle();
      await wheel(const Offset(0, -300));
      expect(refreshes, 1);
    },
  );

  testWidgets(
    'account refresh preserves the mounted app instead of auth loading',
    (tester) async {
      final pending = Completer<UserProfile>();
      var requests = 0;
      final container = ProviderContainer(
        overrides: [
          meProvider.overrideWith((ref) {
            requests++;
            return requests == 1 ? Future.value(DemoSeed.me) : pending.future;
          }),
          shellPagesProvider.overrideWithValue(const [
            Text('Existing feed'),
            SizedBox(),
            SizedBox(),
            SizedBox(),
            SizedBox(),
          ]),
          socialRelationshipHydrationProvider.overrideWith((ref) async {}),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AppScaffold()),
        ),
      );
      await tester.pumpAndSettle();
      final original = tester.element(find.text('Existing feed'));
      container.invalidate(meProvider);
      await tester.pump();
      expect(find.text('Loading your account...'), findsNothing);
      expect(tester.element(find.text('Existing feed')), same(original));
      pending.complete(DemoSeed.me);
      await tester.pumpAndSettle();
      expect(tester.element(find.text('Existing feed')), same(original));
    },
  );
}
