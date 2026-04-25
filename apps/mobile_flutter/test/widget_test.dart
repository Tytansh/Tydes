import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_flutter/app/app.dart';

void main() {
  testWidgets('renders surf travel shell', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SurfTravelApp()));
    await tester.pumpAndSettle();

    expect(find.text('Surf Travel'), findsWidgets);
  });
}
