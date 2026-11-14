import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/features/admin/admin_feature_library_loader.dart';
import 'package:mobile_flutter/features/admin/admin_feature_page.dart';
import 'package:mobile_flutter/features/admin/admin_feature_page_web.dart'
    show AdminFeatureLoadGate;
import 'package:mobile_flutter/features/admin/admin_users_page.dart';

class _EmptyReports extends AdminReportsController {
  @override
  Future<List<AdminReport>> build() async => [];
}

void main() {
  test(
    'admin code download coalesces and caches only successful loads',
    () async {
      final pending = Completer<void>();
      var loads = 0;
      final loader = AdminFeatureLibraryLoader(() {
        loads++;
        return pending.future;
      });
      final first = loader.load();
      expect(loader.load(), same(first));
      expect(loader.isLoaded, isFalse);
      expect(loads, 1);
      pending.complete();
      await first;
      await loader.load();
      expect(loader.isLoaded, isTrue);
      expect(loads, 1);
    },
  );

  for (final synchronous in [true, false]) {
    test(
      'admin load failure permits retry (synchronous: $synchronous)',
      () async {
        var loads = 0;
        final loader = AdminFeatureLibraryLoader(() {
          if (++loads == 1) {
            if (synchronous) throw StateError('offline');
            return Future<void>.error(StateError('offline'));
          }
          return Future<void>.value();
        });
        await expectLater(loader.load(), throwsStateError);
        expect(loader.isLoaded, isFalse);
        await loader.load();
        expect(loader.isLoaded, isTrue);
        expect(loads, 2);
      },
    );
  }

  testWidgets('admin shell retains loaded page state across parent updates', (
    tester,
  ) async {
    final pending = Completer<void>();
    var loads = 0;
    var builds = 0;
    Widget shell() => MaterialApp(
      home: AdminFeatureLoadGate(
        loadLibrary: () {
          loads++;
          return pending.future;
        },
        buildPage: (_) {
          builds++;
          return const _StatefulAdmin();
        },
      ),
    );
    await tester.pumpWidget(shell());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(builds, 0);
    pending.complete();
    await tester.pump();
    await tester.tap(find.text('Visits: 0'));
    await tester.pump();
    await tester.pumpWidget(shell());
    expect(find.text('Visits: 1'), findsOneWidget);
    expect(builds, 1);
    expect(loads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('admin load error shows a working retry', (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AdminFeatureLoadGate(
          loadLibrary: () async {
            if (++loads == 1) throw StateError('offline');
          },
          buildPage: (_) => const Text('Admin loaded'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry admin tools'), findsOneWidget);
    await tester.tap(find.text('Retry admin tools'));
    await tester.pumpAndSettle();
    expect(find.text('Admin loaded'), findsOneWidget);
    expect(loads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached admin code avoids a loading frame', (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AdminFeatureLoadGate(
          libraryLoaded: true,
          loadLibrary: () async => loads++,
          buildPage: (_) => const Text('Cached admin'),
        ),
      ),
    );
    expect(find.text('Cached admin'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(loads, 0);
  });

  testWidgets('admin download completion after leaving cannot mount its page', (
    tester,
  ) async {
    final pending = Completer<void>();
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AdminFeatureLoadGate(
          loadLibrary: () => pending.future,
          buildPage: (_) {
            builds++;
            return const Text('Late admin');
          },
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete();
    await tester.pump();
    expect(builds, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native admin route retains synchronous page construction', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          adminUsersProvider.overrideWith((_) async => []),
          adminReportsProvider.overrideWith(_EmptyReports.new),
        ],
        child: const MaterialApp(home: AdminFeaturePage()),
      ),
    );
    expect(find.byType(AdminUsersPage), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('TYDES admin'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _StatefulAdmin extends StatefulWidget {
  const _StatefulAdmin();
  @override
  State<_StatefulAdmin> createState() => _StatefulAdminState();
}

class _StatefulAdminState extends State<_StatefulAdmin> {
  var visits = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () => setState(() => visits++),
      child: Text('Visits: $visits'),
    ),
  );
}
