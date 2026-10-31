import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

void main() {
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
