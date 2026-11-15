import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/post_composer_feature_page_web.dart';
import 'package:mobile_flutter/features/social/post_composer_library_loader.dart';

void main() {
  test(
    'composer code requests coalesce and successful code stays loaded',
    () async {
      final ready = Completer<void>();
      var requests = 0;
      final loader = PostComposerLibraryLoader(() {
        requests++;
        return ready.future;
      });
      final first = loader.load();
      final second = loader.load();
      expect(second, same(first));
      expect(requests, 1);
      expect(loader.isLoaded, isFalse);
      ready.complete();
      await Future.wait([first, second]);
      expect(loader.isLoaded, isTrue);
      await loader.load();
      expect(requests, 1);
    },
  );

  test(
    'failed composer code requests can retry without caching the error',
    () async {
      var requests = 0;
      final loader = PostComposerLibraryLoader(() async {
        if (++requests == 1) throw StateError('Synthetic unavailable chunk');
      });
      await expectLater(loader.load(), throwsStateError);
      expect(loader.isLoaded, isFalse);
      await loader.load();
      expect(requests, 2);
      expect(loader.isLoaded, isTrue);
    },
  );

  testWidgets('composer does not mount before code loading completes', (
    tester,
  ) async {
    final ready = Completer<void>();
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PostComposerLoadGate(
          loadLibrary: () => ready.future,
          buildPage: (_) {
            builds++;
            return const Scaffold(body: Text('Loaded editor'));
          },
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(builds, 0);
    ready.complete();
    await tester.pumpAndSettle();
    expect(find.text('Loaded editor'), findsOneWidget);
    expect(builds, 1);
  });

  testWidgets(
    'asynchronously loaded composer retains edits on parent rebuild',
    (tester) async {
      final ready = Completer<void>();
      final text = TextEditingController();
      addTearDown(text.dispose);
      late StateSetter rebuild;
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, update) {
              rebuild = update;
              return PostComposerLoadGate(
                loadLibrary: () => ready.future,
                buildPage: (_) {
                  builds++;
                  return Scaffold(body: TextField(controller: text));
                },
              );
            },
          ),
        ),
      );
      ready.complete();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Unsent surf caption');
      final field = tester.widget<TextField>(find.byType(TextField));
      rebuild(() {});
      await tester.pumpAndSettle();
      expect(builds, 1);
      expect(tester.widget<TextField>(find.byType(TextField)), same(field));
      expect(text.text, 'Unsent surf caption');
    },
  );

  testWidgets('already loaded composer skips downloading and mounts once', (
    tester,
  ) async {
    var requests = 0;
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PostComposerLoadGate(
          libraryLoaded: true,
          loadLibrary: () async {
            requests++;
          },
          buildPage: (_) {
            builds++;
            return const Scaffold(body: Text('Cached editor'));
          },
        ),
      ),
    );
    expect(find.text('Cached editor'), findsOneWidget);
    expect(requests, 0);
    expect(builds, 1);
  });

  testWidgets('composer loading error offers a working retry', (tester) async {
    final retry = Completer<void>();
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PostComposerLoadGate(
          loadLibrary: () async {
            if (++requests == 1) throw StateError('Synthetic chunk failure');
            await retry.future;
          },
          buildPage: (_) => const Scaffold(body: Text('Retried editor')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Could not load the post editor'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry post editor'));
    await tester.pump();
    expect(requests, 2);
    expect(find.text('Retried editor'), findsNothing);
    retry.complete();
    await tester.pumpAndSettle();
    expect(find.text('Retried editor'), findsOneWidget);
  });

  testWidgets(
    'Close during composer loading pops the route and ignores late completion',
    (tester) async {
      final ready = Completer<void>();
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => PostComposerLoadGate(
                      loadLibrary: () => ready.future,
                      buildPage: (_) {
                        builds++;
                        return const Scaffold(body: Text('Must not mount'));
                      },
                    ),
                  ),
                ),
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open editor'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      ready.complete();
      await tester.pumpAndSettle();
      expect(find.text('Open editor'), findsOneWidget);
      expect(builds, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Close remains available after a composer code-load failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => PostComposerLoadGate(
                    loadLibrary: () async =>
                        throw StateError('Synthetic chunk failure'),
                    buildPage: (_) =>
                        const Scaffold(body: Text('Must not mount')),
                  ),
                ),
              ),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Could not load the post editor'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Open editor'), findsOneWidget);
    expect(find.text('Must not mount'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing a loading gate consumes a late load error safely', (
    tester,
  ) async {
    final ready = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: PostComposerLoadGate(
          loadLibrary: () => ready.future,
          buildPage: (_) => const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    ready.completeError(StateError('Synthetic late chunk failure'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
