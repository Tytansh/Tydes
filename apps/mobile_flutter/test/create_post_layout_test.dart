import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

void main() {
  testWidgets(
    'event composer preserves the selected audience and explains guest visibility',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 1400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  onPressed: () => showCreatePostSheet(context, const []),
                  child: const Text('Create'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Event'));
      await tester.pumpAndSettle();
      expect(find.text('Public'), findsOneWidget);
      expect(
        find.text('Public event: anyone can see it on the guest map.'),
        findsOneWidget,
      );
      expect(find.text('Choose an event date before posting.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Sunset surf');
      await tester.pumpAndSettle();
      final postButton = find.widgetWithText(FilledButton, 'Post event');
      expect(tester.widget<FilledButton>(postButton).onPressed, isNull);
      await tester.ensureVisible(find.text('Public'));
      await tester.tap(find.text('Public'));
      await tester.pumpAndSettle();
      expect(
        find.text('Followers-only event: hidden from the guest map.'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Post'));
      await tester.tap(find.text('Post'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Event'));
      await tester.pumpAndSettle();
      expect(find.text('Followers'), findsOneWidget);
      expect(
        find.text('Followers-only event: hidden from the guest map.'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byTooltip('Close'));
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Create'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop post composer matches the feed media width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showCreatePostSheet(context, const []),
                  child: const Text('Create'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('New post'), findsOneWidget);
    final mediaStage = tester.getSize(find.byType(AspectRatio).first);
    expect(mediaStage.width, lessThanOrEqualTo(680));
    expect(mediaStage.width, greaterThanOrEqualTo(670));
    expect(mediaStage.height, mediaStage.width);
  });
}
