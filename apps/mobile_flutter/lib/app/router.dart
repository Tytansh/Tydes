import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/alerts/alerts_page.dart';
import '../features/auth/auth_page.dart';
import '../features/home/home_page.dart';
import '../features/paywall/paywall_page.dart';
import '../features/settings/settings_page.dart';
import '../features/spots/spot_detail_page.dart';
import '../features/spots/spots_map_page.dart';
import '../features/spots/spots_page.dart';
import '../features/trips/trips_page.dart';
import '../features/core/app_scaffold.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const AppScaffold(),
        routes: [
          GoRoute(
            path: 'spot/:spotId',
            builder: (context, state) =>
                SpotDetailPage(spotId: state.pathParameters['spotId']!),
          ),
          GoRoute(
            path: 'spots-map',
            builder: (context, state) => const SpotsMapPage(),
          ),
          GoRoute(path: 'login', builder: (context, state) => const AuthPage()),
          GoRoute(
            path: 'paywall',
            builder: (context, state) => const PaywallPage(),
          ),
        ],
      ),
    ],
  );
});

final currentTabProvider = StateProvider<int>((ref) => 0);
final localeProvider = StateProvider<Locale>((ref) => const Locale('en'));

const shellPages = <Widget>[
  HomePage(),
  SpotsPage(),
  TripsPage(),
  AlertsPage(),
  SettingsPage(),
];
