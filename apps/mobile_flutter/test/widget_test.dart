import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_flutter/app/app.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/features/home/home_page.dart';

void main() {
  testWidgets('renders surf travel shell', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          shellPagesProvider.overrideWithValue(
            List<Widget>.filled(5, const Scaffold(body: Text('Smoke shell'))),
          ),
          meProvider.overrideWith(
            (_) async => UserProfile(
              id: 'usr_test',
              email: 'test@example.com',
              displayName: 'Test Surfer',
              handle: 'testsurfer',
              bio: '',
              surfSkill: 'intermediate',
              avatarUrl: null,
              homeRegion: '',
              locale: 'en',
              premium: false,
              emailVerified: true,
              freeLiveSpotId: null,
              adsEnabled: true,
              favoriteSpotIds: const [],
            ),
          ),
        ],
        child: const SurfTravelApp(enableAlertMonitor: false),
      ),
    );
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Smoke shell'), findsOneWidget);
  });
}
