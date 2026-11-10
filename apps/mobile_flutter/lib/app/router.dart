import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/network/api_models.dart';

import '../features/alerts/alerts_page.dart';
import '../features/admin/admin_users_page.dart';
import '../features/auth/auth_page.dart';
import '../features/auth/auth_return_path.dart';
import '../features/public_previews/public_preview_page.dart';
import '../features/guest/guest_explore_page.dart';
import '../features/home/home_page.dart';
import '../features/paywall/paywall_page.dart';
import '../features/settings/settings_page.dart';
import '../features/social/direct_messages_page.dart';
import '../features/social/event_chat_page.dart';
import '../features/social/notifications_page.dart';
import '../features/social/public_profile_page.dart';
import '../features/social/social_profile.dart';
import '../features/spots/spots_map_page.dart';
import '../features/spots/spots_page.dart';
import '../features/trips/trips_page.dart';
import '../features/core/app_scaffold.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => AuthPage(
          initialProfile: state.extra is UserProfile
              ? state.extra as UserProfile
              : null,
          returnTo: safeAuthReturnPath(state.uri.queryParameters['next']),
        ),
      ),
      GoRoute(path: '/explore', builder: (_, _) => const GuestExplorePage()),
      GoRoute(path: '/explore/map', redirect: (_, _) => '/explore'),
      GoRoute(path: '/explore/events', redirect: (_, _) => '/explore'),
      GoRoute(
        path: '/spot/:spotId',
        builder: (_, state) =>
            SharedSpotPage(spotId: state.pathParameters['spotId']!),
      ),
      GoRoute(
        path: '/post/:postId',
        builder: (_, state) =>
            SharedEventPage(postId: state.pathParameters['postId']!),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) => const AppScaffold(),
        routes: [
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
            path: 'admin',
            builder: (context, state) => const AdminUsersPage(),
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
            path: 'event/:postId/chat',
            builder: (context, state) =>
                EventChatPage(postId: state.pathParameters['postId']!),
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
