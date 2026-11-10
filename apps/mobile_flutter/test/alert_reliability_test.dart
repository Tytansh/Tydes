import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/notifications/notification_service.dart';
import 'package:mobile_flutter/features/alerts/alert_monitor.dart';
import 'package:mobile_flutter/features/alerts/alerts_page.dart';
import 'package:mobile_flutter/features/alerts/create_alert_sheet.dart';
import 'package:mobile_flutter/features/spots/spots_page.dart';

Map<String, dynamic> alertJson({
  String id = 'real-alert',
  bool enabled = true,
  double wave = 1.2,
}) => {
  'id': id,
  'spot_id': DemoSeed.spots.first.id,
  'wave_enabled': true,
  'min_wave_height_m': wave,
  'wind_enabled': true,
  'max_wind_kts': 14,
  'tide_enabled': false,
  'enabled': enabled,
  'next_check_at': '2026-11-10T12:00:00Z',
};

ResponseBody response(Object data, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

class MemoryAlertPersistence extends DemoPersistence {
  int alertWrites = 0;
  int alertReads = 0;
  @override
  Future<void> saveAlerts(List<AlertModel> alerts) async {
    alertWrites++;
  }

  @override
  Future<List<AlertModel>> loadAlerts() async {
    alertReads++;
    return DemoSeed.alerts;
  }
}

class _Transport implements HttpClientAdapter {
  _Transport(this.handler);
  final Future<ResponseBody> Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);
  @override
  void close({bool force = false}) {}
}

SurfRepository repository(
  Future<ResponseBody> Function(RequestOptions) handler, [
  MemoryAlertPersistence? persistence,
]) => SurfRepository(
  Dio(BaseOptions(baseUrl: 'https://test.invalid'))
    ..httpClientAdapter = _Transport(handler),
  persistence ?? MemoryAlertPersistence(),
);

Future<Object?> operation(SurfRepository repo, String name) async {
  switch (name) {
    case 'read':
      return repo.fetchAlerts();
    case 'create':
      return repo.createAlert(
        spotId: DemoSeed.spots.first.id,
        waveEnabled: true,
        minWaveHeightM: 2,
        windEnabled: true,
        maxWindKts: 14,
        tideEnabled: false,
      );
    case 'edit':
      return repo.updateAlert(
        alertId: 'real-alert',
        spotId: DemoSeed.spots.first.id,
        waveEnabled: true,
        minWaveHeightM: 2,
        windEnabled: true,
        maxWindKts: 14,
        tideEnabled: false,
        enabled: true,
      );
    case 'toggle':
      return repo.updateAlertEnabled(alertId: 'real-alert', enabled: false);
    case 'delete':
      await repo.deleteAlert('real-alert');
      return null;
  }
  throw StateError('Unknown test operation');
}

class _QuietMonitor extends AlertMonitor {
  _QuietMonitor(SurfRepository repo)
    : super(repository: repo, notifications: NotificationService());
  @override
  Future<void> checkNow() async {}
}

Future<ProviderContainer> showAlerts(
  WidgetTester tester,
  SurfRepository repo,
) async {
  final container = ProviderContainer(
    overrides: [
      surfRepositoryProvider.overrideWithValue(repo),
      spotsProvider.overrideWith((_) async => [DemoSeed.spots.first]),
      alertMonitorProvider.overrideWithValue(_QuietMonitor(repo)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: AlertsPage()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  for (final name in ['read', 'create', 'edit', 'toggle', 'delete']) {
    for (final status in [401, 403, 404, 409, 429, 503, 'timeout', 'offline']) {
      test(
        '$name rejects $status without fabricating or persisting alerts',
        () async {
          final memory = MemoryAlertPersistence();
          final original = List<AlertModel>.of(DemoSeed.alerts);
          final repo = repository((options) async {
            if (status is String) {
              throw DioException(
                requestOptions: options,
                type: status == 'timeout'
                    ? DioExceptionType.receiveTimeout
                    : DioExceptionType.connectionError,
              );
            }
            return response({
              'detail': 'Request rejected for test',
            }, status as int);
          }, memory);
          await expectLater(
            operation(repo, name),
            throwsA(isA<DioException>()),
          );
          expect(DemoSeed.alerts, orderedEquals(original));
          expect(memory.alertWrites, 0);
          expect(memory.alertReads, 0);
        },
      );
    }
  }

  test('deletion requires an explicit server confirmation', () async {
    final repo = repository((_) async => response({'deleted': false}));
    await expectLater(repo.deleteAlert('real-alert'), throwsStateError);
  });

  for (final name in ['edit', 'toggle']) {
    test('$name rejects a response for a different alert', () async {
      final repo = repository(
        (_) async => response(alertJson(id: 'another-alert')),
      );
      await expectLater(operation(repo, name), throwsStateError);
    });
  }

  for (final name in ['create', 'edit', 'toggle', 'delete']) {
    test(
      '$name keeps confirmed state until acknowledgement and supports retry',
      () async {
        final pending = Completer<ResponseBody>();
        final started = Completer<void>();
        var retry = false;
        var reads = 0;
        final repo = repository((options) async {
          if (options.method == 'GET') {
            reads++;
            return response([alertJson()]);
          }
          if (!retry) {
            started.complete();
            return pending.future;
          }
          return name == 'delete'
              ? response({'deleted': true})
              : response(
                  alertJson(
                    id: name == 'create' ? 'new-alert' : 'real-alert',
                    enabled: name != 'toggle',
                    wave: 2,
                  ),
                );
        });
        final container = ProviderContainer(
          overrides: [surfRepositoryProvider.overrideWithValue(repo)],
        );
        addTearDown(container.dispose);
        await container.read(alertsProvider.future);
        final controller = container.read(alertsProvider.notifier);
        Future<Object?> change() async {
          if (name == 'delete') {
            await controller.delete('real-alert');
            return null;
          }
          if (name == 'toggle') {
            await controller.setEnabled('real-alert', false);
            return null;
          }
          return controller.save(
            alertId: name == 'edit' ? 'real-alert' : null,
            spotId: DemoSeed.spots.first.id,
            waveEnabled: true,
            minWaveHeightM: 2,
            windEnabled: true,
            maxWindKts: 14,
            tideEnabled: false,
          );
        }

        final first = change();
        final rejected = expectLater(first, throwsA(isA<DioException>()));
        await started.future;
        expect(
          container.read(alertsProvider).requireValue.single.minWaveHeightM,
          1.2,
        );
        expect(
          container.read(alertsProvider).requireValue.single.enabled,
          isTrue,
        );
        pending.complete(response({}, 503));
        await rejected;
        expect(
          container.read(alertsProvider).requireValue.single.id,
          'real-alert',
        );
        retry = true;
        await change();
        final saved = container.read(alertsProvider).requireValue;
        if (name == 'delete') {
          expect(saved, isEmpty);
        } else if (name == 'create') {
          expect(saved.map((a) => a.id), ['new-alert', 'real-alert']);
        } else {
          expect(saved.single.minWaveHeightM, 2);
          expect(saved.single.enabled, name != 'toggle');
        }
        expect(
          reads,
          1,
          reason: 'A confirmed save must not depend on a second list request.',
        );
      },
    );
  }

  test('an initially failed read is retried before saving', () async {
    var healthy = false;
    final repo = repository((options) async {
      if (!healthy) return response({}, 503);
      return options.method == 'GET'
          ? response([alertJson()])
          : response(alertJson(wave: 2));
    });
    final container = ProviderContainer(
      overrides: [surfRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(alertsProvider.future),
      throwsA(isA<DioException>()),
    );
    healthy = true;
    await container
        .read(alertsProvider.notifier)
        .save(
          alertId: 'real-alert',
          spotId: DemoSeed.spots.first.id,
          waveEnabled: true,
          minWaveHeightM: 2,
          windEnabled: true,
          maxWindKts: 14,
          tideEnabled: false,
        );
    expect(
      container.read(alertsProvider).requireValue.single.minWaveHeightM,
      2,
    );
  });

  test('an old account response cannot overwrite the new alert list', () async {
    final pending = Completer<ResponseBody>();
    final started = Completer<void>();
    var account = 'account-a';
    final repo = repository((options) async {
      if (options.method == 'GET') return response([alertJson(id: account)]);
      started.complete();
      return pending.future;
    });
    final container = ProviderContainer(
      overrides: [surfRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    await container.read(alertsProvider.future);
    final change = container
        .read(alertsProvider.notifier)
        .setEnabled('account-a', false);
    final rejected = expectLater(change, throwsStateError);
    await started.future;
    account = 'account-b';
    container.invalidate(alertsProvider);
    await container.read(alertsProvider.future);
    pending.complete(response(alertJson(id: 'account-a', enabled: false)));
    await rejected;
    expect(container.read(alertsProvider).requireValue.single.id, 'account-b');
  });

  testWidgets(
    'failed toggle keeps original value and retry uses server result',
    (tester) async {
      final pending = Completer<ResponseBody>();
      var retry = false;
      final repo = repository((options) async {
        if (options.method == 'GET') return response([alertJson()]);
        return retry ? response(alertJson(enabled: false)) : pending.future;
      });
      await showAlerts(tester, repo);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      pending.complete(response({}, 503));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.textContaining('Could not update alert'), findsOneWidget);
      retry = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed swipe deletion restores the row and retry removes it only on success',
    (tester) async {
      final pending = Completer<ResponseBody>();
      var retry = false;
      final repo = repository((options) async {
        if (options.method == 'GET') return response([alertJson()]);
        return retry ? response({'deleted': true}) : pending.future;
      });
      final container = await showAlerts(tester, repo);
      await tester.drag(find.byType(Dismissible), const Offset(-700, 0));
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.read(alertsProvider).requireValue, hasLength(1));
      pending.complete(response({}, 503));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dismiss-real-alert')), findsOneWidget);
      expect(find.textContaining('Could not delete alert'), findsOneWidget);
      retry = true;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('dismiss-real-alert')), findsNothing);
      expect(container.read(alertsProvider).requireValue, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final editing in [false, true]) {
    testWidgets(
      '${editing ? 'edit' : 'create'} failure retains form settings and permits retry',
      (tester) async {
        var retry = false;
        final payloads = <Map<String, dynamic>>[];
        final repo = repository((options) async {
          if (options.method == 'GET') return response([alertJson()]);
          payloads.add(Map<String, dynamic>.from(options.data as Map));
          return retry ? response(alertJson(wave: 2)) : response({}, 503);
        });
        await showAlerts(tester, repo);
        await tester.tap(
          editing ? find.byTooltip('Edit alert') : find.text('Add alert'),
        );
        await tester.pumpAndSettle();
        tester.widget<Slider>(find.byType(Slider).first).onChanged!(2);
        await tester.pump();
        final save = find.widgetWithText(
          FilledButton,
          editing ? 'Save changes' : 'Save alert',
        );
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(find.byType(CreateAlertSheet), findsOneWidget);
        expect(find.textContaining('Could not save alert'), findsOneWidget);
        expect(tester.widget<Slider>(find.byType(Slider).first).value, 2);
        expect(find.text('Alert saved.'), findsNothing);
        expect(find.text('Alert updated.'), findsNothing);
        retry = true;
        final again = find.widgetWithText(FilledButton, 'Try again');
        await tester.ensureVisible(again);
        await tester.pumpAndSettle();
        await tester.tap(again);
        await tester.pumpAndSettle();
        expect(find.byType(CreateAlertSheet), findsNothing);
        expect(
          find.text(editing ? 'Alert updated.' : 'Alert saved.'),
          findsOneWidget,
        );
        expect(payloads, hasLength(2));
        expect(
          payloads.first['min_wave_height_m'],
          payloads.last['min_wave_height_m'],
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('failed list reads display an error and a working Retry button', (
    tester,
  ) async {
    var healthy = false;
    final repo = repository(
      (_) async => healthy ? response([alertJson()]) : response({}, 503),
    );
    await showAlerts(tester, repo);
    expect(find.textContaining('Could not load alerts'), findsOneWidget);
    expect(find.byType(Dismissible), findsNothing);
    healthy = true;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(Dismissible), findsOneWidget);
  });
}
