import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/spots/map_feature_library_loader.dart';
import 'package:mobile_flutter/features/spots/map_feature_page_web.dart';

void main() {
  test(
    'map code download is shared and successful loading is cached',
    () async {
      final pending = Completer<void>();
      var loads = 0;
      final loader = MapFeatureLibraryLoader(() {
        loads++;
        return pending.future;
      });
      final first = loader.load();
      expect(loader.load(), same(first));
      expect(loader.isLoaded, isFalse);
      expect(loads, 1);
      pending.complete();
      await first;
      expect(loader.isLoaded, isTrue);
      await loader.load();
      expect(loads, 1);
    },
  );

  test('failed map code download can be retried', () async {
    var loads = 0;
    final loader = MapFeatureLibraryLoader(() async {
      if (++loads == 1) throw StateError('offline');
    });
    await expectLater(loader.load(), throwsStateError);
    expect(loader.isLoaded, isFalse);
    await loader.load();
    expect(loader.isLoaded, isTrue);
    expect(loads, 2);
  });

  test('synchronous map loading errors also permit a retry', () async {
    var loads = 0;
    final loader = MapFeatureLibraryLoader(() {
      if (++loads == 1) throw StateError('offline');
      return Future<void>.value();
    });
    await expectLater(loader.load(), throwsStateError);
    await loader.load();
    expect(loads, 2);
    expect(loader.isLoaded, isTrue);
  });

  testWidgets('map page is built once and retained across parent updates', (
    tester,
  ) async {
    final pending = Completer<void>();
    var loads = 0;
    var builds = 0;
    Future<void> load() {
      loads++;
      return pending.future;
    }

    Widget shell() => MaterialApp(
      home: MapFeatureLoadGate(
        loadLibrary: load,
        buildPage: (_) {
          builds++;
          return const _RetainedMap();
        },
      ),
    );
    await tester.pumpWidget(shell());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(builds, 0);
    pending.complete();
    await tester.pump();
    await tester.tap(find.text('Map visits: 0'));
    await tester.pump();
    expect(find.text('Map visits: 1'), findsOneWidget);
    await tester.pumpWidget(shell());
    expect(find.text('Map visits: 1'), findsOneWidget);
    expect(loads, 1);
    expect(builds, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('map loading failure has a working retry', (tester) async {
    var loads = 0;
    final pending = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: MapFeatureLoadGate(
          loadLibrary: () {
            if (++loads == 1) return Future<void>.error(StateError('offline'));
            return pending.future;
          },
          buildPage: (_) => const Text('Loaded map'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Retry map'), findsOneWidget);
    await tester.tap(find.text('Retry map'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete();
    await tester.pump();
    expect(find.text('Loaded map'), findsOneWidget);
    expect(loads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached map code renders without a loading frame', (
    tester,
  ) async {
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MapFeatureLoadGate(
          libraryLoaded: true,
          loadLibrary: () async => loads++,
          buildPage: (_) => const Text('Cached map'),
        ),
      ),
    );
    expect(find.text('Cached map'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(loads, 0);
  });

  testWidgets('late map download completion is safe after navigation away', (
    tester,
  ) async {
    final pending = Completer<void>();
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MapFeatureLoadGate(
          loadLibrary: () => pending.future,
          buildPage: (_) {
            builds++;
            return const Text('Map');
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
}

class _RetainedMap extends StatefulWidget {
  const _RetainedMap();

  @override
  State<_RetainedMap> createState() => _RetainedMapState();
}

class _RetainedMapState extends State<_RetainedMap> {
  var visits = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      onPressed: () => setState(() => visits++),
      child: Text('Map visits: $visits'),
    ),
  );
}
