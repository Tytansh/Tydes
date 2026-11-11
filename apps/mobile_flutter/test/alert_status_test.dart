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
  statusReason: status == 'waiting' ? 'Waiting on tide data.' : null,
  lastEvaluatedAt: evaluated,
  nextCheckAt: next,
);

class _SnapshotAlerts extends AlertsController {
  _SnapshotAlerts(this.load);
  final List<AlertModel> Function() load;

  @override
  Future<List<AlertModel>> build() async => load();
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
            expect(find.text('Waiting on tide data.'), findsOneWidget);
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
      expect(find.text('Waiting for data'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
