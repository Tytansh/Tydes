import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/alerts/alert_state.dart';
import 'package:mobile_flutter/features/alerts/alert_status.dart';
import 'package:mobile_flutter/features/alerts/alerts_page.dart';
import 'package:mobile_flutter/features/spots/spots_page.dart';

final _now = DateTime.utc(2026, 11, 12, 4);

AlertModel _alert({
  String status = 'triggered',
  bool enabled = true,
  String? evaluated = '2026-11-12T03:00:00Z',
  String next = '2026-11-12T07:00:00Z',
  String? reason = 'Waiting on tide data.',
}) => AlertModel(
  id: 'test-alert',
  spotId: DemoSeed.spots.first.id,
  waveEnabled: true,
  minWaveHeightM: 1,
  windEnabled: true,
  maxWindKts: 24,
  tideEnabled: true,
  tideType: 'high',
  tideOffsetHours: -1,
  enabled: enabled,
  status: status,
  statusReason: status == 'waiting' ? reason : null,
  lastEvaluatedAt: evaluated,
  nextCheckAt: next,
);

class _SnapshotAlerts extends AlertsController {
  _SnapshotAlerts(this.load);
  final List<AlertModel> Function() load;

  @override
  Future<List<AlertModel>> build() async => load();
}

Future<void> _showBanner(
  WidgetTester tester, {
  required AlertModel alert,
  bool dark = false,
  bool compact = false,
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Align(
            alignment: Alignment.topCenter,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: AlertStatusBanner(
                  alert: alert,
                  now: _now,
                  compact: compact,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  test('only a current server-confirmed match gets matched styling', () {
    expect(surfAlertState(_alert(), now: _now), SurfAlertState.matched);
    expect(
      surfAlertState(_alert(status: 'watching'), now: _now),
      SurfAlertState.watching,
    );
    expect(
      surfAlertState(_alert(status: 'waiting'), now: _now),
      SurfAlertState.waiting,
    );
    expect(
      surfAlertState(_alert(enabled: false), now: _now),
      SurfAlertState.off,
    );
    for (final stale in [
      _alert(next: '2026-11-12T04:00:00Z'),
      _alert(next: '2026-11-11T00:00:00Z'),
      _alert(evaluated: null),
      _alert(evaluated: 'invalid'),
      _alert(next: 'invalid'),
      _alert(evaluated: '2026-11-12T05:00:00Z'),
      _alert(evaluated: '2026-11-11T00:00:00Z'),
    ]) {
      expect(surfAlertState(stale, now: _now), SurfAlertState.updateDue);
    }
  });

  test('threshold summary preserves units and tide offset', () {
    expect(
      alertConditionsSummary(_alert()),
      'Wave at least 1 m  •  Wind less than 24 kts  •  1h before high tide',
    );
  });

  for (final dark in [false, true]) {
    for (final width in [320.0, 390.0, 1280.0]) {
      for (final state in SurfAlertState.values) {
        testWidgets('$state at $width in ${dark ? 'dark' : 'light'}', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 1100);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final alert = switch (state) {
            SurfAlertState.matched => _alert(),
            SurfAlertState.watching => _alert(status: 'watching'),
            SurfAlertState.waiting => _alert(status: 'waiting'),
            SurfAlertState.off => _alert(enabled: false),
            SurfAlertState.updateDue => _alert(next: _now.toIso8601String()),
          };
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(20),
                  child: AlertStatusBanner(alert: alert, now: _now),
                ),
              ),
            ),
          );
          expect(
            find.byKey(ValueKey('alert-status-${state.name}')),
            findsOneWidget,
          );
          expect(find.textContaining('Wave at least 1 m'), findsOneWidget);
          expect(
            find.text('Surf alert matched'),
            state == SurfAlertState.matched ? findsOneWidget : findsNothing,
          );
          if (state == SurfAlertState.waiting) {
            expect(find.text('Tide check unavailable'), findsOneWidget);
            expect(
              find.text(
                'Your alert is saved, but we couldn’t confirm the tide condition.',
              ),
              findsOneWidget,
            );
            expect(find.text('Waiting on tide data.'), findsNothing);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets(
    'narrow alert cards keep edit and switch usable and refresh status',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var reads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            alertsProvider.overrideWith(
              () => _SnapshotAlerts(() {
                reads++;
                return [_alert(status: reads == 1 ? 'watching' : 'waiting')];
              }),
            ),
            spotsProvider.overrideWith((_) async => [DemoSeed.spots.first]),
          ],
          child: MaterialApp(theme: AppTheme.dark(), home: const AlertsPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Watching conditions'), findsOneWidget);
      expect(find.byTooltip('Edit alert'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Refresh alerts'));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text('Tide check unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  const tideDetail =
      'Your alert is saved, but we couldn’t confirm the tide condition.';
  const forecastDetail =
      'Your alert is saved, but we couldn’t confirm the forecast conditions.';
  const genericDetail =
      'Your alert is saved, but its conditions couldn’t be checked.';
  for (final (reason, title, detail) in <(String?, String, String)>[
    ('Waiting on tide data.', 'Tide check unavailable', tideDetail),
    ('Waiting on tide events.', 'Tide check unavailable', tideDetail),
    ('Waiting on wave data.', 'Forecast check unavailable', forecastDetail),
    ('Waiting on wind data.', 'Forecast check unavailable', forecastDetail),
    (
      'Waiting on wave data, wind data.',
      'Forecast check unavailable',
      forecastDetail,
    ),
    ('Waiting on tide data, wave data.', 'Check unavailable', genericDetail),
    ('Waiting on wind data, tide events.', 'Check unavailable', genericDetail),
    (
      'Waiting on tide data, another source.',
      'Check unavailable',
      genericDetail,
    ),
    (null, 'Check unavailable', genericDetail),
    ('', 'Check unavailable', genericDetail),
    ('Unknown tide provider result.', 'Check unavailable', genericDetail),
    (
      'Spot not found.',
      'Spot unavailable',
      'The spot for this alert couldn’t be found.',
    ),
    (
      'Waiting on an alert condition to be selected.',
      'Choose alert conditions',
      'Add conditions to finish setting up this alert.',
    ),
  ]) {
    testWidgets('unavailable reason $reason is presented as $title', (
      tester,
    ) async {
      await _showBanner(
        tester,
        alert: _alert(status: 'waiting', reason: reason),
      );
      expect(find.text(title), findsOneWidget);
      expect(find.text(detail), findsOneWidget);
      expect(find.text('Waiting for data'), findsNothing);
      expect(find.textContaining('Checked '), findsOneWidget);
      expect(find.textContaining('Next check '), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final dark in [false, true]) {
    for (final compact in [false, true]) {
      testWidgets(
        'unavailable styling is compact and neutral ${dark ? 'dark' : 'light'} compact=$compact',
        (tester) async {
          await _showBanner(
            tester,
            alert: _alert(status: 'waiting'),
            dark: dark,
            compact: compact,
          );
          final panel = tester.widget<Container>(
            find.byKey(const ValueKey('alert-status-waiting')),
          );
          final context = tester.element(find.byType(AlertStatusBanner));
          final theme = Theme.of(context);
          final decoration = panel.decoration! as BoxDecoration;
          expect(panel.padding, const EdgeInsets.all(12));
          expect(decoration.color, theme.colorScheme.surfaceContainerLow);
          expect(
            decoration.color,
            isNot(dark ? const Color(0xFF3B3425) : const Color(0xFFFFF3DB)),
          );
          expect(
            (decoration.border! as Border).top.color,
            theme.colorScheme.outlineVariant,
          );
          final title = tester.widget<Text>(
            find.text('Tide check unavailable'),
          );
          expect(title.style!.fontSize, 16);
          final icon = tester.widget<Icon>(
            find.byIcon(Icons.info_outline_rounded),
          );
          expect(icon.size, 18);
          expect(title.style!.color, isNot(const Color(0xFF694A12)));
          expect(title.style!.color, isNot(const Color(0xFFFFDB94)));
          final waitingHeight = tester
              .getSize(find.byKey(const ValueKey('alert-status-waiting')))
              .height;
          await _showBanner(
            tester,
            alert: _alert(),
            dark: dark,
            compact: compact,
          );
          final matched = tester.widget<Container>(
            find.byKey(const ValueKey('alert-status-matched')),
          );
          expect(
            tester
                .widget<Text>(find.text('Surf alert matched'))
                .style!
                .fontSize,
            greaterThan(16),
          );
          expect(
            (matched.decoration! as BoxDecoration).color,
            dark ? const Color(0xFF123F37) : const Color(0xFFDFF7ED),
          );
          expect(
            tester
                .getSize(find.byKey(const ValueKey('alert-status-matched')))
                .height,
            greaterThan(waitingHeight),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      'unavailable at 320px and 2x text in ${dark ? 'dark' : 'light'}',
      (tester) async {
        await _showBanner(
          tester,
          alert: _alert(status: 'waiting', reason: 'Waiting on wave data.'),
          width: 320,
          textScale: 2,
          dark: dark,
        );
        expect(find.text('Forecast check unavailable'), findsOneWidget);
        expect(find.text(forecastDetail), findsOneWidget);
        final panel = tester.getRect(
          find.byKey(const ValueKey('alert-status-waiting')),
        );
        expect(panel.width, 280);
        expect(panel.left, greaterThanOrEqualTo(0));
        expect(panel.right, lessThanOrEqualTo(320));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('matched watching paused and expired copy stays distinct', (
    tester,
  ) async {
    for (final (alert, title, detail) in [
      (
        _alert(),
        'Surf alert matched',
        'Your conditions match the latest forecast check.',
      ),
      (
        _alert(status: 'watching'),
        'Watching conditions',
        'We’re watching for your chosen conditions.',
      ),
      (
        _alert(enabled: false),
        'Alert paused',
        'Turn this alert on to watch for your conditions.',
      ),
      (
        _alert(next: _now.toIso8601String()),
        'Update due',
        'Previously matched. Refresh alerts for the latest check.',
      ),
    ]) {
      await _showBanner(tester, alert: alert);
      expect(find.text(title), findsOneWidget);
      expect(find.text(detail), findsOneWidget);
      expect(find.textContaining('unavailable'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
