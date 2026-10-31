import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/trips/trips_page.dart';

void main() {
  test('offline seed includes twenty known Taiwan surf spots', () {
    final taiwanSpots = DemoSeed.spots
        .where((spot) => spot.country == 'Taiwan')
        .toList();

    expect(taiwanSpots, hasLength(20));
    expect(
      taiwanSpots.map((spot) => spot.name),
      containsAll(const [
        'Wushi Harbor',
        'Baishawan',
        'Beibin Park',
        'Baxiandong',
        'Changbin',
        'Xiaoyugang',
        'Jihui',
        'Duli',
      ]),
    );
  });

  test('offline seed does not invent a trip for the user', () {
    expect(DemoSeed.trips, isEmpty);
    expect(DemoSeed.dashboard.upcomingTrip, isNull);
  });

  testWidgets('travel shows real destinations and honest coming-soon states', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          travelSpotsProvider.overrideWith((_) async => DemoSeed.spots),
          nextSwellProvider.overrideWith(
            (_) async => NextSwellModel(
              available: true,
              spotId: 'spot_snapper',
              spotName: 'Snapper Rocks',
              destination: 'Gold Coast, Australia',
              country: 'Australia',
              region: 'Queensland',
              area: 'Gold Coast',
              bestDay: '2026-10-27',
              waveHeightM: 2.4,
              swellHeightM: 2.1,
              periodS: 14,
              windKts: 8,
              quality: 'epic',
              source: 'open-meteo',
              confidence: 'live',
              updatedAt: '2026-10-24T02:00:00Z',
              summary:
                  'Snapper Rocks has the strongest travel signal in the next five days.',
              note:
                  'Forecast-model guidance for trip planning, not a safety call.',
            ),
          ),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const TripsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Go where the swell is.'), findsOneWidget);
    expect(find.text('Everything you need around the break'), findsOneWidget);
    expect(find.text('Hostels & stays'), findsOneWidget);
    expect(find.text('Scooter rentals'), findsOneWidget);
    expect(find.text('Board shops'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('NEXT SWELL'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('NEXT SWELL'), findsOneWidget);
    expect(find.text('Gold Coast, Australia'), findsOneWidget);
    expect(find.textContaining('Best break • Snapper Rocks'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Choose your coast'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Surf bases worth a look'), findsNothing);
    expect(find.text('Choose your coast'), findsOneWidget);
    expect(find.text('Swell outlooks and surf events'), findsNothing);
    expect(find.textContaining('We removed the demo itinerary'), findsNothing);
    expect(find.text('Dry Season Surf Sprint'), findsNothing);
  });
}
