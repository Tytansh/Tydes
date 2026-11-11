// Local visual QA only. Never publish a build using this entrypoint.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/admin/admin_users_page.dart';

void main() => runApp(
  ProviderScope(
    overrides: [surfRepositoryProvider.overrideWithValue(_ReportsPreview())],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const _LocalAdminPreview(),
    ),
  ),
);

class _LocalAdminPreview extends StatelessWidget {
  const _LocalAdminPreview();
  @override
  Widget build(BuildContext context) => const Column(
    children: [
      Material(
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.all(8),
            child: Text('LOCAL VISUAL QA • sample reports only'),
          ),
        ),
      ),
      Expanded(child: AdminUsersPage()),
    ],
  );
}

class _ReportsPreview extends SurfRepository {
  _ReportsPreview() : super(_blockedApi(), DemoPersistence());
  final reports = [
    AdminReport.fromJson({
      'id': 'sample-report',
      'reporter_user_id': 'sample-reporter',
      'reporter_handle': 'preview',
      'target_type': 'post',
      'target_id': 'sample-post',
      'reason': 'Spam or scam',
      'created_at': '2026-11-05T04:51:00Z',
      'reported_user_id': 'sample-author',
      'reported_handle': 'surfer',
      'target_available': false,
    }),
  ];

  @override
  Future<List<AdminUserAccount>> fetchAdminUsers() async => [];
  @override
  Future<List<AdminReport>> fetchAdminReports() async => List.of(reports);
  @override
  Future<void> setAdminReportStatus({
    required String reportId,
    required bool dismissed,
  }) async {
    final index = reports.indexWhere((report) => report.id == reportId);
    reports[index] = reports[index].withDismissed(dismissed);
  }
}

Dio _blockedApi() => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          message: 'Visual QA cannot access any backend.',
        ),
      ),
    ),
  );
