import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/alerts/alerts_page.dart';
import '../features/auth/auth_page.dart';
import '../features/home/home_page.dart';
import '../features/paywall/paywall_page.dart';
import '../features/settings/settings_page.dart';
import '../features/social/direct_messages_page.dart';
import '../features/social/notifications_page.dart';
import '../features/social/post_detail_page.dart';
import '../features/social/public_profile_page.dart';
import '../features/social/social_profile.dart';
import '../features/spots/spot_detail_page.dart';
import '../features/spots/spots_map_page.dart';
import '../features/spots/spots_page.dart';
import '../features/trips/trips_page.dart';
import '../features/core/app_scaffold.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/login', builder: (context, state) => const AuthPage()),
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
            builder: (context, state) => SpotsMapPage(
              initialSpotId: state.uri.queryParameters['spotId'],
            ),
          ),
          GoRoute(
            path: 'people-search',
            builder: (context, state) => const PeopleSearchPage(),
          ),
          GoRoute(
            path: 'paywall',
            builder: (context, state) => const PaywallPage(),
          ),
          GoRoute(
            path: 'messages',
            builder: (context, state) {
              final extra = state.extra;
              return DirectMessagesPage(
                initialThreadId: state.uri.queryParameters['thread'],
                seedProfile: extra is PublicProfilePreview ? extra : null,
              );
            },
          ),
          GoRoute(
            path: 'notifications',
            builder: (context, state) => const SocialNotificationsPage(),
          ),
          GoRoute(
            path: 'post/:postId',
            builder: (context, state) =>
                PostDetailPage(postId: state.pathParameters['postId']!),
          ),
          GoRoute(
            path: 'profile/:userId',
            builder: (context, state) {
              final extra = state.extra;
              return PublicProfilePage(
                userId: state.pathParameters['userId']!,
                initialPostId: state.uri.queryParameters['post'],
                seedProfile: extra is PublicProfilePreview ? extra : null,
              );
            },
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

final shellPagesProvider = Provider<List<Widget>>((ref) => shellPages);
