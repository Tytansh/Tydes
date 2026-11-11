import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/features/spots/spot_picker.dart';

void main() {
  testWidgets('dark spot picker uses dark regional sections', (tester) async {
    final theme = ThemeData.dark(useMaterial3: true).copyWith(
      cardColor: const Color(0xFF172D32),
      scaffoldBackgroundColor: const Color(0xFF0C1C21),
    );
    final spots = List.generate(
      6,
      (index) => SpotModel(
        id: 'spot-$index',
        name: 'Break $index',
        country: 'Indonesia',
        region: 'Bali',
        area: 'Canggu',
        latitude: -8.64,
        longitude: 115.13,
        difficulty: 'intermediate',
        bestMonths: const ['May'],
        waveHeightM: 1,
        waterTempC: 26,
        imageUrl: '',
        summary: 'A surf break.',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SpotPickerField(
            spots: spots,
            favoriteSpotIds: const {},
            selectedSpotId: null,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose spot'));
    await tester.pumpAndSettle();
    expect(find.text('Bali'), findsOneWidget);
    final region = find
        .ancestor(
          of: find.text('Bali'),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox && widget.decoration is BoxDecoration,
          ),
        )
        .first;
    expect(
      (tester.widget<DecoratedBox>(region).decoration as BoxDecoration).color,
      theme.colorScheme.surfaceContainerLow,
    );
    expect(tester.takeException(), isNull);
  });
}
