import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/trips/trips_page.dart';

void main() {
  testWidgets('travel opens with useful trip and destination content', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          travelSpotsProvider.overrideWith((_) async => DemoSeed.spots),
          tripsProvider.overrideWith((_) async => DemoSeed.trips),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const TripsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Go where the swell is.'), findsOneWidget);
    expect(find.text('Dry Season Surf Sprint'), findsOneWidget);
    expect(find.text('Surf bases worth a look'), findsOneWidget);
    expect(find.text('Uluwatu'), findsWidgets);
  });
}
