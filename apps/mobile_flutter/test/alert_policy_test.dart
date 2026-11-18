import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_flutter/app/router.dart' show currentTabProvider;
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/alerts/alert_policy.dart';
import 'package:mobile_flutter/features/alerts/alert_state.dart';
import 'package:mobile_flutter/features/alerts/alert_status.dart';
import 'package:mobile_flutter/features/alerts/create_alert_sheet.dart';
import 'package:mobile_flutter/features/home/home_page.dart';

UserProfile _profile({
  bool premium = false,
  bool verified = true,
  String? spotId = 'uluwatu',
}) => DemoSeed.me.copyWith(
  id: 'policy-account',
  premium: premium,
  emailVerified: verified,
  freeLiveSpotId: spotId,
  clearFreeLiveSpotId: spotId == null,
);

Map<String, dynamic> _alertJson({
  String id = 'alert-1',
  String spotId = 'uluwatu',
  bool enabled = true,
  String? pauseReason,
}) => {
  'id': id,
  'spot_id': spotId,
  'wave_enabled': true,
  'min_wave_height_m': 1.2,
  'wind_enabled': true,
  'max_wind_kts': 14,
  'tide_enabled': true,
  'tide_type': 'high',
  'tide_offset_hours': -1,
  'enabled': enabled,
  'pause_reason': pauseReason,
  'next_check_at': '2026-11-18T12:00:00Z',
};

AlertModel _alert({
  String id = 'alert-1',
  String spotId = 'uluwatu',
  bool enabled = true,
  String? pauseReason,
}) => AlertModel.fromJson(
  _alertJson(
    id: id,
    spotId: spotId,
    enabled: enabled,
    pauseReason: pauseReason,
  ),
);

class _MemoryRepository extends SurfRepository {
  _MemoryRepository() : super(Dio(), DemoPersistence());
  int reads = 0;
  @override
  Future<List<AlertModel>> fetchAlerts() async {
    reads++;
    return [_alert(enabled: false, pauseReason: 'spot_access')];
  }
}

class _SnapshotAlerts extends AlertsController {
  _SnapshotAlerts(this.items);
  final List<AlertModel> items;
  @override
  Future<List<AlertModel>> build() async => items;
}

void main() {
  for (final premium in [false, true]) {
    testWidgets(
      '${premium ? 'Premium cap Manage alerts' : 'Free wrong-spot Choose free spot'} navigates to the correct root tab without alert mutations',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var requests = 0;
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                requests++;
                handler.reject(
                  DioException(
                    requestOptions: options,
                    message: 'The navigation fixture must not contact an API.',
                  ),
                );
              },
            ),
          );
        final paused = _alert(
          id: 'paused',
          enabled: false,
          pauseReason: 'spot_access',
        );
        final rows = [
          if (premium)
            for (var i = 0; i < 10; i++) _alert(id: 'active-$i'),
          paused,
        ];
        final profile = _profile(premium: premium, spotId: 'another-free-spot');
        final container = ProviderContainer(
          overrides: [
            surfRepositoryProvider.overrideWithValue(
              SurfRepository(dio, DemoPersistence()),
            ),
            meProvider.overrideWith((_) async => profile),
            alertsProvider.overrideWith(() => _SnapshotAlerts(rows)),
          ],
        );
        addTearDown(container.dispose);
        await container.read(meProvider.future);
        await container.read(alertsProvider.future);
        final router = GoRouter(
          initialLocation: '/sheet',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) =>
                  const Scaffold(body: Text('Root navigation target')),
            ),
            GoRoute(
              path: '/sheet',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) =>
                        CreateAlertSheet(spots: [DemoSeed.spots.first]),
                  ),
                  child: const Text('Open alert form'),
                ),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open alert form'));
        await tester.pumpAndSettle();
        expect(find.byType(CreateAlertSheet), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Save alert'),
              )
              .onPressed,
          isNull,
        );
        final action = find.text(
          premium ? 'Manage alerts' : 'Choose free spot',
        );
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/');
        expect(container.read(currentTabProvider), premium ? 3 : 1);
        expect(find.text('Root navigation target'), findsOneWidget);
        expect(find.byType(CreateAlertSheet), findsNothing);
        final confirmed = container.read(alertsProvider).requireValue;
        expect(confirmed, hasLength(premium ? 11 : 1));
        expect(
          confirmed.singleWhere((alert) => alert.id == paused.id).enabled,
          isFalse,
        );
        expect(
          confirmed.singleWhere((alert) => alert.id == paused.id).pauseReason,
          'spot_access',
        );
        expect(
          requests,
          0,
          reason: 'A navigation CTA must not create, enable or edit an alert.',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('active alert limits are one for Free and ten for Premium', () {
    expect(activeAlertLimit(_profile()), 1);
    expect(activeAlertLimit(_profile(premium: true)), 10);
  });

  test('creation requires a loaded and verified account', () {
    expect(
      alertActivationBlock(profile: null, alerts: [], spotId: 'uluwatu'),
      isNotNull,
    );
    for (final premium in [false, true]) {
      expect(
        alertActivationBlock(
          profile: _profile(premium: premium, verified: false),
          alerts: [],
          spotId: 'uluwatu',
        ),
        isNotNull,
      );
    }
  });

  test('Free access is the exact selected spot and includes tide alerts', () {
    final free = _profile();
    expect(
      alertActivationBlock(profile: free, alerts: [], spotId: 'uluwatu'),
      isNull,
    );
    for (final target in ['padang', 'Uluwatu', '']) {
      expect(
        alertActivationBlock(profile: free, alerts: [], spotId: target),
        isNotNull,
      );
    }
    expect(
      alertActivationBlock(
        profile: _profile(spotId: null),
        alerts: [],
        spotId: 'uluwatu',
      ),
      isNotNull,
    );
    // Tide-only/all-rule configuration does not create a separate Premium gate.
    final selected = _alert();
    expect(selected.tideEnabled, isTrue);
    expect(
      alertActivationBlock(
        profile: free,
        alerts: [selected],
        spotId: selected.spotId,
        editingAlertId: selected.id,
      ),
      isNull,
    );
  });

  test(
    'Free quota counts enabled alerts only and excludes the edited alert',
    () {
      final active = _alert();
      final paused = _alert(
        id: 'paused',
        enabled: false,
        pauseReason: 'spot_access',
      );
      expect(
        alertActivationBlock(
          profile: _profile(),
          alerts: [paused],
          spotId: 'uluwatu',
        ),
        isNull,
      );
      expect(
        alertActivationBlock(
          profile: _profile(),
          alerts: [active, paused],
          spotId: 'uluwatu',
        ),
        isNotNull,
      );
      expect(
        alertActivationBlock(
          profile: _profile(),
          alerts: [active, paused],
          spotId: 'uluwatu',
          editingAlertId: active.id,
        ),
        isNull,
      );
      expect(
        alertActivationBlock(
          profile: _profile(),
          alerts: [active, paused],
          spotId: 'uluwatu',
          editingAlertId: paused.id,
        ),
        isNotNull,
      );
    },
  );

  test('Premium allows any selected spot but caps enabled alerts at ten', () {
    final premium = _profile(premium: true, spotId: null);
    final nine = [for (var i = 0; i < 9; i++) _alert(id: 'active-$i')];
    final ten = [...nine, _alert(id: 'active-9')];
    final paused = [
      for (var i = 0; i < 12; i++)
        _alert(id: 'paused-$i', enabled: false, pauseReason: 'active_limit'),
    ];
    expect(
      alertActivationBlock(
        profile: premium,
        alerts: [...nine, ...paused],
        spotId: 'padang',
      ),
      isNull,
    );
    expect(
      alertActivationBlock(
        profile: premium,
        alerts: [...ten, ...paused],
        spotId: 'padang',
      ),
      isNotNull,
    );
    expect(
      alertActivationBlock(
        profile: premium,
        alerts: [...ten, ...paused],
        spotId: 'padang',
        editingAlertId: ten.first.id,
      ),
      isNull,
    );
    expect(
      alertActivationBlock(
        profile: premium,
        alerts: [...ten, ...paused],
        spotId: 'padang',
        editingAlertId: paused.first.id,
      ),
      isNotNull,
    );
  });

  test(
    'pause reason parsing preserves legacy data and saved configuration',
    () {
      final legacy = _alertJson(enabled: false)..remove('pause_reason');
      expect(AlertModel.fromJson(legacy).pauseReason, isNull);
      expect(_alert(enabled: false).pauseReason, isNull);
      for (final reason in ['spot_access', 'active_limit']) {
        final paused = _alert(enabled: false, pauseReason: reason);
        expect(paused.pauseReason, reason);
        expect(paused.enabled, isFalse);
        expect(paused.spotId, 'uluwatu');
        expect(paused.waveEnabled, isTrue);
        expect(paused.minWaveHeightM, 1.2);
        expect(paused.windEnabled, isTrue);
        expect(paused.maxWindKts, 14);
        expect(paused.tideEnabled, isTrue);
        expect(paused.tideType, 'high');
        expect(paused.tideOffsetHours, -1);
      }
    },
  );

  for (final dark in [false, true]) {
    for (final (reason, detail) in <(String?, String)>[
      (
        'spot_access',
        'This alert needs live data at its spot. Select it as your free spot or use Premium, then turn the alert back on.',
      ),
      (
        'active_limit',
        'Your active alert limit was reached. Pause another alert before turning this one back on.',
      ),
      (null, 'Turn this alert on to watch for your conditions.'),
      ('future_reason', 'Turn this alert on to watch for your conditions.'),
    ]) {
      testWidgets('paused $reason copy in ${dark ? 'dark' : 'light'} mode', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: AlertStatusBanner(
                  alert: _alert(enabled: false, pauseReason: reason),
                  now: DateTime.utc(2026, 11, 18),
                ),
              ),
            ),
          ),
        );
        expect(find.text('Alert paused'), findsOneWidget);
        expect(find.text(detail), findsOneWidget);
        expect(find.text('Surf alert matched'), findsNothing);
        expect(find.byKey(const ValueKey('alert-status-off')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  test(
    'confirmed entitlement changes refresh cached alerts without auto-resume',
    () async {
      var profile = _profile();
      final repository = _MemoryRepository();
      final container = ProviderContainer(
        overrides: [
          surfRepositoryProvider.overrideWithValue(repository),
          meProvider.overrideWith((_) async => profile),
        ],
      );
      addTearDown(container.dispose);
      await container.read(meProvider.future);
      await container.read(alertsProvider.future);
      expect(repository.reads, 1);
      for (final next in [
        profile.copyWith(premium: true),
        profile.copyWith(premium: false),
        profile.copyWith(freeLiveSpotId: 'padang'),
        profile.copyWith(id: 'another-account'),
      ]) {
        profile = next;
        final previousReads = repository.reads;
        container.invalidate(meProvider);
        await container.read(meProvider.future);
        final alerts = await container.read(alertsProvider.future);
        expect(repository.reads, greaterThan(previousReads));
        expect(alerts.single.enabled, isFalse);
        expect(alerts.single.pauseReason, 'spot_access');
      }
    },
  );
}
