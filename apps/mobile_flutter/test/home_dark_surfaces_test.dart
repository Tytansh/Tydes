import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

Future<void> _show(WidgetTester tester, ThemeData theme, Widget page) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        meProvider.overrideWith((_) async => DemoSeed.me),
        socialProfilesProvider.overrideWith((_) async => []),
        travelFeedPostsProvider.overrideWith((_) async => []),
        peopleSearchPostsProvider.overrideWith((_) async => []),
        travelFeedSpotsProvider.overrideWith((_) async => []),
        socialEngagementHydrationProvider.overrideWith((_) async {}),
        socialRelationshipHydrationProvider.overrideWith((_) async {}),
      ],
      child: MaterialApp(theme: theme, home: page),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final dark in [false, true]) {
    final name = dark ? 'dark' : 'light';
    testWidgets('feed search uses a readable $name surface', (tester) async {
      final theme = dark ? AppTheme.dark() : AppTheme.light();
      await _show(tester, theme, const HomePage());
      final pill = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('Search surfers'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect((pill.decoration! as BoxDecoration).color, theme.cardColor);
      expect(tester.takeException(), isNull);
    });

    testWidgets('people search uses a readable $name input', (tester) async {
      final theme = dark ? AppTheme.dark() : AppTheme.light();
      await _show(tester, theme, const PeopleSearchPage());
      final input = tester.widget<TextField>(find.byType(TextField));
      expect(input.decoration!.fillColor, theme.cardColor);
      expect(tester.takeException(), isNull);
    });
  }
}
