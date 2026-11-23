import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/core/widgets/phone_frosted_chrome.dart';
import 'package:mobile_flutter/features/core/app_scaffold.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/inbox_badges.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

final _posts = List.generate(
  20,
  (index) => SocialPostModel.fromJson({
    'id': 'glass-post-$index',
    'user_id': DemoSeed.me.id,
    'author_name': 'Surfer',
    'post_type': 'general',
    'body': 'Glass scroll post $index',
    'created_at': '2026-11-23T00:00:00Z',
    'media': [],
  }),
);

Future<ProviderContainer> _show(
  WidgetTester tester, {
  double width = 430,
  Brightness brightness = Brightness.dark,
  double top = 59,
  double bottom = 34,
  bool highContrast = false,
  bool disableAnimations = false,
  Completer<List<SocialPostModel>>? refreshedPosts,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 932);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  var fetches = 0;
  final container = ProviderContainer(
    overrides: [
      meProvider.overrideWith((_) async => DemoSeed.me),
      travelFeedPostsProvider.overrideWith((_) async {
        if (++fetches > 1 && refreshedPosts != null) {
          return refreshedPosts.future;
        }
        return _posts;
      }),
      travelFeedSpotsProvider.overrideWith((_) async => []),
      socialRelationshipHydrationProvider.overrideWith((_) async {}),
      inboxUnreadCountsProvider.overrideWith(
        (_) async => InboxUnreadCounts(accountId: DemoSeed.me.id),
      ),
      shellPagesProvider.overrideWithValue(const [
        HomePage(),
        Center(child: Text('Spots test tab')),
        Center(child: Text('Travel test tab')),
        Center(child: Text('Alerts test tab')),
        Center(child: Text('Profile test tab')),
      ]),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: EdgeInsets.only(top: top, bottom: bottom),
            viewPadding: EdgeInsets.only(top: top, bottom: bottom),
            highContrast: highContrast,
            disableAnimations: disableAnimations,
          ),
          child: child!,
        ),
        home: const AppScaffold(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder get _scrollable => find
    .descendant(
      of: find.byType(CustomScrollView),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    )
    .first;

Finder get _tints => find.byKey(const ValueKey('phone-frosted-chrome-tint'));

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('phone glass stays clipped and readable in $brightness', (
      tester,
    ) async {
      await _show(tester, brightness: brightness);
      expect(find.byType(PhoneFrostedChrome), findsNWidgets(2));
      expect(find.byType(BackdropFilter), findsNWidgets(2));
      for (final element in _tints.evaluate()) {
        final decoration =
            (element.widget as DecoratedBox).decoration as BoxDecoration;
        expect(decoration.color!.a, inExclusiveRange(.8, 1));
        expect(
          find.ancestor(
            of: find.byWidget(element.widget),
            matching: find.byType(Opacity),
          ),
          findsNothing,
        );
      }
      expect(tester.getSize(find.byType(AppBar)).height, 44);
      expect(tester.getSize(find.byType(NavigationBar)).height, 90);
      final tintRects = _tints.evaluate().map(
        (element) => tester.getRect(find.byWidget(element.widget)),
      );
      expect(tintRects.every((rect) => rect.height <= 90), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('feed starts below glass and can scroll behind it', (
    tester,
  ) async {
    await _show(tester);
    final bar = tester.getRect(find.byType(AppBar));
    final viewport = tester.getRect(find.byType(CustomScrollView));
    final chrome = tester.widget<FeedChromeInsets>(
      find.byType(FeedChromeInsets),
    );
    expect(viewport.top, 59);
    expect(viewport.bottom, 932);
    expect(chrome.viewportHeight, 873);
    expect(chrome.insets, const EdgeInsets.only(top: 44, bottom: 90));
    expect(tester.getTopLeft(find.byType(Card).first).dy, bar.bottom + 20);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -160));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(Card).first).dy, lessThan(bar.bottom));
    final position = tester.state<ScrollableState>(_scrollable).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final lastPost = find.text('Glass scroll post 19');
    expect(lastPost, findsOneWidget);
    expect(
      tester.getBottomRight(lastPost).dy,
      lessThan(tester.getTopLeft(find.byType(NavigationBar)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('wider layouts keep opaque non-overlay chrome', (tester) async {
    await _show(tester, width: 800, top: 0, bottom: 0);
    expect(find.byType(PhoneFrostedChrome), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.getSize(find.byType(AppBar)).height, 56);
    expect(tester.getSize(find.byType(NavigationBar)).height, 80);
    final chrome = tester.widget<FeedChromeInsets>(
      find.byType(FeedChromeInsets),
    );
    expect(chrome.insets, EdgeInsets.zero);
    expect(
      tester.getTopLeft(find.byType(Card).first).dy,
      tester.getBottomRight(find.byType(AppBar)).dy + 20,
    );
    expect(tester.takeException(), isNull);
  });

  for (final highContrast in [false, true]) {
    testWidgets('accessibility prefers solid chrome: contrast $highContrast', (
      tester,
    ) async {
      await _show(
        tester,
        highContrast: highContrast,
        disableAnimations: !highContrast,
      );
      expect(find.byType(PhoneFrostedChrome), findsNWidgets(2));
      expect(find.byType(BackdropFilter), findsNothing);
      for (final element in _tints.evaluate()) {
        expect(
          ((element.widget as DecoratedBox).decoration as BoxDecoration)
              .color!
              .a,
          1,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('switching to another tab restores normal body geometry', (
    tester,
  ) async {
    final container = await _show(tester);
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    expect(container.read(currentTabProvider), 1);
    expect(find.text('Spots test tab'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(
      find
          .ancestor(
            of: find.byType(NavigationBar),
            matching: find.byType(Scaffold),
          )
          .first,
    );
    expect(scaffold.extendBody, isFalse);
    expect(tester.getSize(find.byType(NavigationBar)).height, 90);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pull-refresh spinner stays below translucent top bar', (
    tester,
  ) async {
    final pending = Completer<List<SocialPostModel>>();
    await _show(tester, refreshedPosts: pending);
    final bar = tester.getRect(find.byType(AppBar));
    final original = tester.element(find.text('Glass scroll post 0'));
    final gesture = await tester.startGesture(const Offset(200, 180));
    await gesture.moveBy(const Offset(0, 250));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 250));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    final spinner = find.byKey(const ValueKey('feed-top-refresh-spinner'));
    expect(spinner, findsOneWidget);
    expect(tester.getTopLeft(spinner).dy, greaterThanOrEqualTo(bar.bottom));
    expect(tester.element(find.text('Glass scroll post 0')), same(original));
    pending.complete(_posts);
    await tester.pumpAndSettle();
    expect(spinner, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
