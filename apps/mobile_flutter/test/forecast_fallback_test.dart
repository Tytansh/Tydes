import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';

void main() {
  test('estimated forecast fallback starts on the current day', () {
    final now = DateTime.now();
    final expected =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';

    expect(DemoSeed.forecasts.first.day, expected);
    expect(DemoSeed.forecasts.first.day, isNot('2026-04-15'));
  });
}
