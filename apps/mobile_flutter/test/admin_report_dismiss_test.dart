import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/admin/admin_users_page.dart';

Map<String, dynamic> _reportJson({
  String id = 'report-one',
  String status = 'open',
  String reason = 'Sample report reason',
}) => {
  'id': id,
  'status': status,
  'reporter_user_id': 'reporter-one',
  'reporter_handle': 'sample_reporter',
  'reporter_display_name': 'Sample Reporter',
  'reported_user_id': 'author-one',
  'reported_handle': 'sample_author',
  'reported_display_name': 'Sample Author',
  'target_type': 'post',
  'target_id': 'post-one',
  'target_available': true,
  'reason': reason,
  'created_at': '2026-11-12T00:00:00Z',
  'dismissed_at': status == 'dismissed' ? '2026-11-12T01:00:00Z' : null,
  'dismissed_by_user_id': status == 'dismissed' ? 'admin-one' : null,
};

ResponseBody _response(Object? body, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

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

SurfRepository _repository(
  Future<ResponseBody> Function(RequestOptions) handler,
) => SurfRepository(
  Dio(BaseOptions(baseUrl: 'https://test.invalid'))
    ..httpClientAdapter = _Transport(handler),
  DemoPersistence(),
);

class _ReportServer {
  final statuses = <String, String>{'report-one': 'open'};
  final requests = <RequestOptions>[];
  Completer<ResponseBody>? pending;
  bool rejectMutation = false;

  Future<ResponseBody> handle(RequestOptions request) async {
    requests.add(request);
    if (request.method == 'GET' && request.path == '/admin/dashboard/users') {
      return _response({'users': [], 'count': 0});
    }
    if (request.method == 'GET' && request.path == '/admin/dashboard/reports') {
      return _response({
        'reports': [
          for (final entry in statuses.entries)
            _reportJson(
              id: entry.key,
              status: entry.value,
              reason: entry.key == 'report-one'
                  ? 'Sample report reason'
                  : 'Previously dismissed reason',
            ),
        ],
        'count': statuses.length,
      });
    }
    if (request.method == 'PATCH' &&
        request.path.startsWith('/admin/dashboard/reports/')) {
      if (pending != null) return pending!.future;
      if (rejectMutation) {
        return _response({'detail': 'Report update rejected for test.'}, 503);
      }
      final id = request.path.split('/').last;
      final status = (request.data as Map)['status'] as String;
      statuses[id] = status;
      return _response(_reportJson(id: id, status: status));
    }
    throw StateError(
      'Unexpected test request ${request.method} ${request.path}',
    );
  }

  List<RequestOptions> get mutations =>
      requests.where((request) => request.method != 'GET').toList();
}

Future<void> _show(
  WidgetTester tester,
  _ReportServer server, {
  Size size = const Size(1200, 1000),
  bool dark = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        surfRepositoryProvider.overrideWithValue(_repository(server.handle)),
      ],
      child: MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        home: const AdminUsersPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _statusButton(String id) => find.byKey(ValueKey('report-status-$id'));

void main() {
  test('legacy reports default to active and dismissal metadata parses', () {
    final legacy = _reportJson()..remove('status');
    final active = AdminReport.fromJson(legacy);
    expect(active.status, 'open');
    expect(active.isDismissed, isFalse);
    expect(active.dismissedAt, isNull);

    final dismissed = AdminReport.fromJson(_reportJson(status: 'dismissed'));
    expect(dismissed.isDismissed, isTrue);
    expect(dismissed.dismissedAt, DateTime.utc(2026, 11, 12, 1));
  });

  test('report reads explicitly request retained dismissed history', () async {
    RequestOptions? request;
    final repository = _repository((options) async {
      request = options;
      return _response({
        'reports': [_reportJson(status: 'dismissed')],
      });
    });
    final reports = await repository.fetchAdminReports();
    expect(request!.method, 'GET');
    expect(request!.path, '/admin/dashboard/reports');
    expect(request!.queryParameters['include_dismissed'], isTrue);
    expect(reports.single.isDismissed, isTrue);
  });

  for (final dismissed in [true, false]) {
    test(
      'report ${dismissed ? 'dismissal' : 'restoration'} verifies response',
      () async {
        final status = dismissed ? 'dismissed' : 'open';
        RequestOptions? request;
        final repository = _repository((options) async {
          request = options;
          return _response({'id': 'report-one', 'status': status});
        });
        await repository.setAdminReportStatus(
          reportId: 'report-one',
          dismissed: dismissed,
        );
        expect(request!.method, 'PATCH');
        expect(request!.path, '/admin/dashboard/reports/report-one');
        expect(request!.data, {'status': status});
      },
    );
  }

  for (final body in [
    <String, Object?>{'id': 'another-report', 'status': 'dismissed'},
    <String, Object?>{'id': 'report-one', 'status': 'open'},
    <String, Object?>{},
  ]) {
    test('mismatched acknowledgement never reports success: $body', () async {
      final repository = _repository((_) async => _response(body));
      await expectLater(
        repository.setAdminReportStatus(
          reportId: 'report-one',
          dismissed: true,
        ),
        throwsStateError,
      );
    });
  }

  for (final status in [401, 403, 404, 429, 503, 'timeout', 'offline']) {
    test('failed report dismissal propagates $status', () async {
      final repository = _repository((options) async {
        if (status is String) {
          throw DioException(
            requestOptions: options,
            type: status == 'timeout'
                ? DioExceptionType.receiveTimeout
                : DioExceptionType.connectionError,
          );
        }
        return _response({'detail': 'Rejected.'}, status as int);
      });
      await expectLater(
        repository.setAdminReportStatus(
          reportId: 'report-one',
          dismissed: true,
        ),
        throwsA(anything),
      );
    });
  }

  testWidgets('dismiss waits for confirmation before removing the report', (
    tester,
  ) async {
    final server = _ReportServer();
    await _show(tester, server);
    server.pending = Completer<ResponseBody>();
    await tester.tap(_statusButton('report-one'));
    await tester.pump();
    expect(find.text('Sample report reason'), findsOneWidget);
    final button = tester.widget<OutlinedButton>(_statusButton('report-one'));
    expect(button.onPressed, isNull);
    server.statuses['report-one'] = 'dismissed';
    server.pending!.complete(_response(_reportJson(status: 'dismissed')));
    await tester.pumpAndSettle();
    expect(find.text('Sample report reason'), findsNothing);
    expect(find.text('Undo'), findsOneWidget);
    expect(server.mutations, hasLength(1));
    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed dismissal leaves the report active and supports retry', (
    tester,
  ) async {
    final server = _ReportServer()..rejectMutation = true;
    await _show(tester, server);
    await tester.tap(_statusButton('report-one'));
    await tester.pumpAndSettle();
    expect(find.text('Sample report reason'), findsOneWidget);
    expect(find.text('Undo'), findsNothing);
    expect(server.statuses['report-one'], 'open');
    server.rejectMutation = false;
    await tester.tap(_statusButton('report-one'));
    await tester.pumpAndSettle();
    expect(find.text('Sample report reason'), findsNothing);
    expect(server.mutations, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Undo restores the dismissed report without banning or deletion',
    (tester) async {
      final server = _ReportServer();
      await _show(tester, server);
      await tester.tap(_statusButton('report-one'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Sample report reason'), findsOneWidget);
      expect(server.statuses['report-one'], 'open');
      final badge = tester.widget<Badge>(find.byType(Badge));
      expect(badge.isLabelVisible, isTrue);
      expect((badge.label! as Text).data, '1');
      expect(server.mutations.map((request) => request.data), [
        {'status': 'dismissed'},
        {'status': 'open'},
      ]);
      expect(
        server.mutations.every(
          (request) =>
              request.method == 'PATCH' &&
              request.path == '/admin/dashboard/reports/report-one',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dismissed history offers restore after the snackbar expires', (
    tester,
  ) async {
    final server = _ReportServer()..statuses['report-two'] = 'dismissed';
    await _show(tester, server);
    expect((tester.widget<Badge>(find.byType(Badge)).label! as Text).data, '1');
    expect(find.text('Previously dismissed reason'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('report-filter-dismissed')));
    await tester.pumpAndSettle();
    expect(find.text('Sample report reason'), findsNothing);
    expect(find.text('Previously dismissed reason'), findsOneWidget);
    expect(find.text('Restore report'), findsOneWidget);
    await tester.tap(_statusButton('report-two'));
    await tester.pumpAndSettle();
    expect(server.statuses['report-two'], 'open');
    await tester.tap(find.byKey(const ValueKey('report-filter-open')));
    await tester.pumpAndSettle();
    expect(find.text('Sample report reason'), findsOneWidget);
    expect(find.text('Previously dismissed reason'), findsOneWidget);
    expect((tester.widget<Badge>(find.byType(Badge)).label! as Text).data, '2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed restore retains dismissed history without reopening it', (
    tester,
  ) async {
    final server = _ReportServer()
      ..statuses['report-one'] = 'dismissed'
      ..rejectMutation = true;
    await _show(tester, server);
    await tester.tap(find.byKey(const ValueKey('report-filter-dismissed')));
    await tester.pumpAndSettle();
    await tester.tap(_statusButton('report-one'));
    await tester.pumpAndSettle();
    expect(find.text('Sample report reason'), findsOneWidget);
    expect(find.text('Restore report'), findsOneWidget);
    expect(server.statuses['report-one'], 'dismissed');
    expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
    expect(find.text('Undo'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('report actions fit a narrow ${dark ? 'dark' : 'light'} page', (
      tester,
    ) async {
      final server = _ReportServer();
      await _show(tester, server, size: const Size(390, 1100), dark: dark);
      expect(find.text('Dismiss report'), findsOneWidget);
      await tester.ensureVisible(_statusButton('report-one'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
