import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

Future<void> _mount(WidgetTester tester) async {
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
  await _open(tester);
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Create'));
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester) async {
  await tester.ensureVisible(find.byTooltip('Close'));
  await tester.tap(find.byTooltip('Close'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'closing and reopening the composer retains restorable caption drafts',
    (tester) async {
      await _mount(tester);
      await tester.enterText(find.byType(TextField), 'Keep this surf caption');
      await _close(tester);
      await _open(tester);
      await tester.tap(find.text('Drafts'));
      await tester.pumpAndSettle();
      expect(find.text('Post draft'), findsOneWidget);
      await tester.tap(find.text('Post draft'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Keep this surf caption',
      );
      expect(find.text('Draft restored.'), findsOneWidget);
      await _close(tester);
      await _open(tester);
      await tester.tap(find.text('Drafts'));
      await tester.pumpAndSettle();
      expect(find.text('Post draft'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete draft'));
      await tester.pumpAndSettle();
      expect(find.text('No drafts yet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'event drafts retain audience and date after leaving the composer',
    (tester) async {
      await _mount(tester);
      await tester.tap(find.text('Event'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Public'));
      await tester.tap(find.text('Tomorrow'));
      await tester.enterText(find.byType(TextField), 'Tomorrow with friends');
      await _close(tester);
      await _open(tester);
      await tester.tap(find.text('Drafts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Event draft'));
      await tester.pumpAndSettle();
      expect(find.text('New event'), findsOneWidget);
      expect(find.text('Followers'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Tomorrow'))
            .selected,
        isTrue,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Tomorrow with friends',
      );
      // A restored date does not bypass the required event-spot guard.
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Post event'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'composer extraction preserves caption character and line limits',
    (tester) async {
      await _mount(tester);
      await tester.enterText(find.byType(TextField), 'a' * 1700);
      expect(
        tester
            .widget<TextField>(find.byType(TextField))
            .controller!
            .text
            .length,
        1600,
      );
      await tester.enterText(
        find.byType(TextField),
        List.filled(18, 'surf').join('\n'),
      );
      expect(
        tester
            .widget<TextField>(find.byType(TextField))
            .controller!
            .text
            .split('\n')
            .length,
        16,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
