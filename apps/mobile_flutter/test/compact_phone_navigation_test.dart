import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/core/app_scaffold.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/inbox_badges.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

Future<ProviderContainer> _show(
  WidgetTester tester, {
  required double width,
  double height = 932,
  double bottomInset = 0,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      meProvider.overrideWith((_) async => DemoSeed.me),
      travelFeedPostsProvider.overrideWith((_) async => []),
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
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: EdgeInsets.only(bottom: bottomInset),
            viewPadding: EdgeInsets.only(bottom: bottomInset),
            textScaler: TextScaler.linear(textScale),
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

Finder get _search => find.byWidgetPredicate(
  (widget) =>
      widget is Semantics && widget.properties.label == 'Search surfers',
);

void main() {
  for (final width in [320.0, 390.0, 430.0, 600.0, 800.0]) {
    testWidgets('phone bars compact without changing wider layouts at $width', (
      tester,
    ) async {
      await _show(tester, width: width);
      final phone = width < 600;
      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      final navigation = tester.widget<NavigationBar>(
        find.byType(NavigationBar),
      );
      expect(appBar.preferredSize.height, phone ? 44 : 56);
      expect(
        tester.getSize(find.byType(NavigationBar)).height,
        phone ? 56 : 80,
      );
      expect(navigation.destinations, hasLength(5));
      expect(
        tester.getSize(_search).height,
        phone ? greaterThanOrEqualTo(44) : 42,
      );
      final pill = find.descendant(
        of: _search,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.constraints?.maxHeight == (phone ? 34 : 42),
        ),
      );
      expect(pill, findsOneWidget);
      for (final tooltip in ['Messages', 'Notifications']) {
        final button = find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(IconButton),
        );
        expect(button, findsOneWidget);
        final hitBox = tester.getSize(button);
        expect(hitBox.width, greaterThanOrEqualTo(44));
        expect(hitBox.height, greaterThanOrEqualTo(44));
      }
      for (final destination in find.byType(NavigationDestination).evaluate()) {
        final box = tester.getSize(find.byWidget(destination.widget));
        expect(box.width, greaterThanOrEqualTo(44));
        expect(box.height, greaterThanOrEqualTo(44));
      }
      if (phone) {
        final postButton = find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(FilledButton),
        );
        expect(tester.getSize(postButton).height, greaterThanOrEqualTo(44));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('compact navigation keeps all five destinations working', (
    tester,
  ) async {
    final container = await _show(tester, width: 390);
    for (var index = 1; index < 5; index++) {
      await tester.tap(find.byType(NavigationDestination).at(index));
      await tester.pumpAndSettle();
      expect(container.read(currentTabProvider), index);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        index,
      );
    }
    await tester.tap(find.byType(NavigationDestination).first);
    await tester.pumpAndSettle();
    expect(container.read(currentTabProvider), 0);
    expect(find.byType(AppBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('iPhone home-indicator inset stays below compact navigation', (
    tester,
  ) async {
    await _show(tester, width: 430, bottomInset: 34);
    final navigation = tester.getRect(find.byType(NavigationBar));
    final destination = tester.getRect(
      find.byType(NavigationDestination).first,
    );
    expect(navigation.height, 56 + 34);
    expect(navigation.bottom, 932);
    expect(destination.height, 56);
    expect(destination.bottom, navigation.bottom - 34);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('phone bars do not overflow at larger accessibility text', (
    tester,
  ) async {
    await _show(tester, width: 390, bottomInset: 34, textScale: 1.5);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(tester.getSize(_search).height, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
