import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_flutter/app/app.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/core/theme/appearance_settings.dart';
import 'package:mobile_flutter/core/theme/theme_preference.dart';
import 'package:mobile_flutter/core/theme/theme_preference_store.dart';

class MemoryThemeStore extends ThemePreferenceStore {
  MemoryThemeStore([this.value]);
  String? value;
  bool fail = false;
  final writes = <String>[];

  @override
  Future<String?> load() async {
    if (fail) throw StateError('Storage unavailable');
    return value;
  }

  @override
  Future<void> save(String mode) async {
    if (fail) throw StateError('Storage unavailable');
    value = mode;
    writes.add(mode);
  }
}

Widget harness(
  MemoryThemeStore store, {
  ThemeMode initial = ThemeMode.system,
}) => ProviderScope(
  overrides: [
    themePreferenceStoreProvider.overrideWithValue(store),
    initialThemeModeProvider.overrideWithValue(initial),
  ],
  child: Consumer(
    builder: (context, ref, _) => MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      home: const Scaffold(body: AppearanceSettingsTile()),
    ),
  ),
);

double contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
}

void main() {
  test(
    'stored values validate and blocked storage falls back to system',
    () async {
      for (final mode in ThemeMode.values) {
        expect(await loadThemeMode(MemoryThemeStore(mode.name)), mode);
      }
      expect(
        await loadThemeMode(MemoryThemeStore('invalid')),
        ThemeMode.system,
      );
      expect(await loadThemeMode(MemoryThemeStore()), ThemeMode.system);
      expect(
        await loadThemeMode(MemoryThemeStore()..fail = true),
        ThemeMode.system,
      );
    },
  );

  test('dark mode is persisted and restored by a fresh controller', () async {
    final store = MemoryThemeStore();
    final controller = ThemeModeController(store, ThemeMode.system);
    expect(await controller.setMode(ThemeMode.dark), isTrue);
    expect(store.value, 'dark');
    final restarted = ThemeModeController(store, await loadThemeMode(store));
    expect(restarted.state, ThemeMode.dark);
    controller.dispose();
    restarted.dispose();
  });

  test(
    'failed save restores the previous selection, not fake success',
    () async {
      final store = MemoryThemeStore('light')..fail = true;
      final controller = ThemeModeController(store, ThemeMode.light);
      expect(await controller.setMode(ThemeMode.dark), isFalse);
      expect(controller.state, ThemeMode.light);
      controller.dispose();
    },
  );

  test('dark text, muted text and primary buttons meet 4.5:1 contrast', () {
    final theme = AppTheme.dark();
    final scheme = theme.colorScheme;
    for (final surface in [
      theme.cardColor,
      theme.scaffoldBackgroundColor,
      scheme.surfaceContainerHigh,
    ]) {
      expect(contrast(scheme.onSurface, surface), greaterThanOrEqualTo(7));
      expect(
        contrast(scheme.onSurfaceVariant, surface),
        greaterThanOrEqualTo(4.5),
      );
    }
    expect(
      contrast(scheme.onPrimary, scheme.primary),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets(
    'appearance switches immediately, persists and can return to light',
    (tester) async {
      final store = MemoryThemeStore();
      await tester.pumpWidget(harness(store, initial: ThemeMode.light));
      await tester.tap(find.byKey(const ValueKey('appearance-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('appearance-dark')));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(AlertDialog))).brightness,
        Brightness.dark,
      );
      expect(store.value, 'dark');
      await tester.tap(find.byKey(const ValueKey('appearance-light')));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(AlertDialog))).brightness,
        Brightness.light,
      );
      expect(store.writes, ['dark', 'light']);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'system mode follows runtime OS changes; explicit light ignores them',
    (tester) async {
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpWidget(harness(MemoryThemeStore()));
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.light,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.dark,
      );
      await tester.tap(find.byKey(const ValueKey('appearance-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('appearance-light')));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.light,
      );
    },
  );

  testWidgets(
    'save errors are visible and selection does not falsely succeed',
    (tester) async {
      final store = MemoryThemeStore('light')..fail = true;
      await tester.pumpWidget(harness(store, initial: ThemeMode.light));
      await tester.tap(find.byKey(const ValueKey('appearance-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('appearance-dark')));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not save appearance. Please try again.'),
        findsOneWidget,
      );
      expect(
        Theme.of(tester.element(find.byType(AlertDialog))).brightness,
        Brightness.light,
      );
    },
  );

  testWidgets(
    'actual app accepts saved dark mode on first frame without navigation',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/retained-route',
        routes: [
          GoRoute(
            path: '/retained-route',
            builder: (_, _) => const Scaffold(body: Text('Retained route')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appRouterProvider.overrideWithValue(router),
            initialThemeModeProvider.overrideWithValue(ThemeMode.dark),
          ],
          child: const SurfTravelApp(enableAlertMonitor: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Retained route'), findsOneWidget);
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        Brightness.dark,
      );
      expect(router.routeInformationProvider.value.uri.path, '/retained-route');
    },
  );
}
