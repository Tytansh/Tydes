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
import 'package:mobile_flutter/features/social/post_media_zoom.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

void main() {
  testWidgets(
    'taps, mouse clicks and short drags never display refresh loading',
    (tester) async {
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FeedRefreshIndicator(
              onRefresh: () async => refreshes++,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [Text('Existing post')],
              ),
            ),
          ),
        ),
      );
      final position = tester.getCenter(find.byType(ListView));
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
        final gesture = await tester.startGesture(position, kind: kind);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(const ValueKey('feed-top-refresh-spinner')),
          findsNothing,
        );
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(const ValueKey('feed-top-refresh-spinner')),
          findsNothing,
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expect(refreshes, 0);
        expect(
          find.byKey(const ValueKey('feed-top-refresh-spinner')),
          findsNothing,
        );
      }
    },
  );

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
    expect(
      find.byKey(const ValueKey('feed-top-refresh-spinner')),
      findsOneWidget,
    );
    expect(tester.element(find.text('Existing post')), same(original));
    pending.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('feed-top-refresh-spinner')),
      findsNothing,
    );
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
      expect(
        find.byKey(const ValueKey('feed-top-refresh-spinner')),
        findsOneWidget,
      );
      expect(find.text('Existing video'), findsOneWidget);
      await wheel(const Offset(0, -300));
      expect(refreshes, 1);
      final spinner = tester.getRect(
        find.byKey(const ValueKey('feed-top-refresh-spinner')),
      );
      final content = tester.getRect(find.byType(ListView));
      expect(spinner.bottom, lessThanOrEqualTo(content.top));
      await wheel(const Offset(0, 80));
      expect(
        find.byKey(const ValueKey('feed-top-refresh-spinner')),
        findsNothing,
      );
      expect(find.text('Existing video'), findsOneWidget);
      pending.complete();
      await tester.pumpAndSettle();
      await wheel(const Offset(0, -300));
      expect(refreshes, 1);
    },
  );

  testWidgets(
    'zoomed trackpad media pan does not trigger the feed refresh listener',
    (tester) async {
      final pending = Completer<void>();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
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
                controller: scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(
                    height: 360,
                    child: PostMediaZoom(
                      showControls: true,
                      child: ColoredBox(
                        color: Colors.blue,
                        child: Text('Mounted media'),
                      ),
                    ),
                  ),
                  SizedBox(height: 1500),
                ],
              ),
            ),
          ),
        ),
      );
      final original = tester.element(find.text('Mounted media'));
      final position = tester.getCenter(find.byType(PostMediaZoom));
      await tester.sendEventToBinding(
        PointerScaleEvent(
          kind: PointerDeviceKind.trackpad,
          position: position,
          scale: 2,
        ),
      );
      await tester.pump();
      for (var index = 0; index < 3; index++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            kind: PointerDeviceKind.trackpad,
            position: position,
            scrollDelta: const Offset(10, -80),
          ),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(seconds: 1));
      expect(refreshes, 0);
      expect(scroll.offset, 0);
      expect(
        find.byKey(const ValueKey('feed-top-refresh-spinner')),
        findsNothing,
      );
      expect(tester.element(find.text('Mounted media')), same(original));

      // A genuine mouse wheel still scrolls normally, even over zoomed media.
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: position,
          scrollDelta: const Offset(0, 140),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(refreshes, 0);
      scroll.jumpTo(0);
      await tester.pump();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: position,
          scrollDelta: const Offset(0, -140),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(refreshes, 1);
      expect(
        find.byKey(const ValueKey('feed-top-refresh-spinner')),
        findsOneWidget,
      );
      expect(tester.element(find.text('Mounted media')), same(original));
      pending.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
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
