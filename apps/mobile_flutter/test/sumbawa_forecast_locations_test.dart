import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';

void main() {
  test('Sumbawa forecast reference areas do not regress to Sape', () {
    const references = {
      'spot_lakey_peak': (-8.79, 118.38, "Hu'u"),
      'spot_lakey_pipe': (-8.80, 118.38, "Hu'u"),
      'spot_nungas': (-8.79, 118.38, "Hu'u"),
      'spot_periscope_point': (-8.78, 118.37, "Hu'u"),
      'spot_cobblestones_sumbawa': (-8.82, 118.38, "Hu'u"),
      'spot_yoyos': (-8.98, 116.73, 'Sekongkang'),
    };
    for (final entry in references.entries) {
      final spot = DemoSeed.spots.singleWhere((spot) => spot.id == entry.key);
      expect(spot.latitude, entry.value.$1);
      expect(spot.longitude, entry.value.$2);
      expect(spot.area, entry.value.$3);
      expect(spot.summary, contains('Approximate forecast-area position'));
    }
  });
}
