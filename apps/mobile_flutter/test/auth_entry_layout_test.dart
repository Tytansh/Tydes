import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/auth/auth_page.dart';

Future<void> showAuth(WidgetTester tester, {ThemeData? theme}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(theme: theme, home: const AuthPage()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(768, 1024),
    const Size(1024, 700),
    const Size(1440, 900),
  ]) {
    testWidgets('photo-led login has one brand and one legal footer at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await showAuth(tester);
      expect(find.byKey(const ValueKey('auth-brand')), findsOneWidget);
      expect(find.text('TYDES'), findsOneWidget);
      expect(find.text('Where We Surfing'), findsOneWidget);
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.text('Terms'), findsOneWidget);
      expect(find.text('Privacy'), findsOneWidget);
      expect(find.text('Support'), findsOneWidget);
      expect(find.text('About & Partnerships'), findsOneWidget);
      expect(find.text('300+ surf breaks'), findsNothing);
      final photo = tester.widget<Image>(
        find.byKey(const ValueKey('auth-surf-photo')),
      );
      expect(
        (photo.image as AssetImage).assetName,
        size.width >= 980
            ? 'assets/images/auth-surf-ocean.webp'
            : 'assets/images/auth-surf-ocean-mobile.webp',
      );
      if (size.width >= 980) {
        final email = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Email',
        );
        expect(tester.getCenter(email).dx, greaterThan(size.width / 2));
        expect(
          tester.getRect(find.byKey(const ValueKey('auth-surf-photo'))).height,
          size.height - 32,
        );
      }
      await tester.ensureVisible(
        find.byKey(const ValueKey('explore-as-guest')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Explore the map'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    testWidgets('dark login preserves photo and readable form at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final theme = AppTheme.dark();
      await showAuth(tester, theme: theme);
      final heading = tester.widget<Text>(find.text('Welcome back'));
      expect(heading.style!.color, theme.colorScheme.onSurface);
      expect(find.byKey(const ValueKey('auth-surf-photo')), findsOneWidget);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        theme.scaffoldBackgroundColor,
      );
      final email = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Email',
      );
      final formTheme = Theme.of(tester.element(email));
      expect(
        formTheme.inputDecorationTheme.fillColor,
        theme.colorScheme.surfaceContainerHigh,
      );
      expect(
        formTheme.inputDecorationTheme.labelStyle!.color,
        theme.colorScheme.onSurfaceVariant,
      );
      final signIn = find.widgetWithText(FilledButton, 'Sign in');
      await tester.ensureVisible(signIn);
      await tester.tap(signIn);
      await tester.pumpAndSettle();
      final errorText = find.text('Enter a valid email address.');
      expect(errorText, findsOneWidget);
      expect(
        tester.widget<Text>(errorText).style!.color,
        theme.colorScheme.onErrorContainer,
      );
      final errorPanel = tester.widget<Container>(
        find.ancestor(of: errorText, matching: find.byType(Container)).first,
      );
      expect(
        (errorPanel.decoration! as BoxDecoration).color,
        theme.colorScheme.errorContainer,
      );
      await tester.ensureVisible(find.text('Sign up'));
      await tester.tap(find.text('Sign up'));
      await tester.pumpAndSettle();
      expect(find.text('Create account'), findsNWidgets(2));
      expect(find.text('Confirm password'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('explore-as-guest')),
      );
      await tester.pumpAndSettle();
      expect(find.text('No account needed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('phone signup remains scrollable when the keyboard is open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await showAuth(tester);
    await tester.ensureVisible(find.text('Sign up'));
    await tester.tap(find.text('Sign up'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final confirmation = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Confirm password',
    );
    await tester.ensureVisible(confirmation);
    await tester.enterText(confirmation, 'not-a-real-password');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('explore-as-guest')));
    await tester.pumpAndSettle();
    expect(find.text('Terms'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
