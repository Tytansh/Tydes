import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/legal/legal_links.dart';

void main() {
  test('native About links target the public TYDES website', () {
    expect(tydesAboutPageUrl, 'https://tydes.io/about/');
  });

  testWidgets(
    'public footer provides About alongside the existing legal links',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TydesLegalLinks(
              includeAbout: true,
              includeSupport: true,
              dense: true,
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('about-partnerships-link')),
        findsOneWidget,
      );
      expect(find.text('About & Partnerships'), findsOneWidget);
      expect(find.text('Terms'), findsOneWidget);
      expect(find.text('Privacy'), findsOneWidget);
      expect(find.text('Support'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('About remains opt-in outside public navigation', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TydesLegalLinks())),
    );
    expect(find.text('About & Partnerships'), findsNothing);
    expect(find.text('Terms'), findsOneWidget);
    expect(find.text('Privacy'), findsOneWidget);
  });
}
