import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/network/api_models.dart';
import '../core/network/surf_repository.dart';

import '../features/alerts/alerts_page.dart';
import '../features/admin/admin_feature_page.dart';
import '../features/auth/auth_page.dart';
import '../features/auth/auth_return_path.dart';
import '../features/auth/verification_gate_page.dart';
import '../features/public_previews/public_preview_page.dart';
import '../features/home/home_page.dart';
import '../features/paywall/paywall_page.dart';
import '../features/settings/settings_page.dart';
import '../features/social/direct_messages_page.dart';
import '../features/social/event_chat_page.dart';
import '../features/social/notifications_page.dart';
import '../features/social/public_profile_page.dart';
import '../features/social/social_profile.dart';
import '../features/spots/map_feature_page.dart';
import '../features/spots/spots_page.dart';
import '../features/trips/trips_page.dart';
import '../features/core/app_scaffold.dart';

final routerInitialLocationProvider = Provider<String>((_) => '/');

bool isPublicAppPath(String path) =>
    path == '/login' ||
    path == '/explore' ||
    path.startsWith('/explore/') ||
    RegExp(r'^/(spot|post)/[A-Za-z0-9_-]{1,120}$').hasMatch(path);

class _AccountRouterRefresh extends ChangeNotifier {
  void changed() => notifyListeners();
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _AccountRouterRefresh();
  ref.listen(meProvider, (_, _) => refresh.changed());
  ref.listen(
    emailVerificationRequiredTokenProvider,
    (_, _) => refresh.changed(),
  );
  final router = GoRouter(
    initialLocation: ref.watch(routerInitialLocationProvider),
    refreshListenable: refresh,
    redirect: (context, state) async {
      final path = state.uri.path;
      if (isPublicAppPath(path)) return null;
      final gate = path == '/verify-email' || path == '/account-check';
      final next = safeAuthReturnPath(
        gate ? state.uri.queryParameters['next'] : state.uri.toString(),
      );
      var account = ref.read(meProvider);
      final retained = account.valueOrNull;
      if (account.isLoading && !account.hasError && retained != null) {
        final sameSession = await ref
            .read(surfRepositoryProvider)
            .canRetainAccountDuringRefresh(retained);
        // Do not tear down an already-authorized page for a normal refresh.
        // Recheck after the async token read so an old session cannot win.
        if (sameSession &&
            identical(ref.read(meProvider), account) &&
            ref.read(emailVerificationRequiredTokenProvider) == null &&
            !needsAccountProfile(retained)) {
          return gate ? next : null;
        }
        account = ref.read(meProvider);
      }
      if (account.isLoading ||
          account.hasError ||
          account.valueOrNull == null) {
        final expired =
            account.hasError &&
            account.error.toString().toLowerCase().contains('session expired');
        if (expired) return loginForPath(next);
        return path == '/account-check'
            ? null
            : Uri(
                path: '/account-check',
                queryParameters: {'next': next},
              ).toString();
      }
      final profile = account.requireValue;
      if (!profile.emailVerified ||
          ref.read(emailVerificationRequiredTokenProvider) != null) {
        return path == '/verify-email' ? null : verificationForPath(next);
      }
      if (needsAccountProfile(profile)) return loginForPath(next);
      return gate ? next : null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => AuthPage(
          initialProfile: state.extra is UserProfile
              ? state.extra as UserProfile
              : switch (ref.read(meProvider).valueOrNull) {
                  final profile?
                      when profile.emailVerified &&
                          needsAccountProfile(profile) =>
                    profile,
                  _ => null,
                },
          returnTo: safeAuthReturnPath(state.uri.queryParameters['next']),
        ),
      ),
      GoRoute(
        path: '/account-check',
        pageBuilder: (_, state) => NoTransitionPage(
          key: state.pageKey,
          child: AccountCheckPage(
            returnTo: safeAuthReturnPath(state.uri.queryParameters['next']),
          ),
        ),
      ),
      GoRoute(
        path: '/verify-email',
        pageBuilder: (_, state) => NoTransitionPage(
          key: state.pageKey,
          child: VerificationGatePage(
            returnTo: safeAuthReturnPath(state.uri.queryParameters['next']),
          ),
        ),
      ),
      GoRoute(
        path: '/explore',
        builder: (_, _) => const MapFeaturePage(guest: true),
      ),
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
            builder: (context, state) => MapFeaturePage(
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
            builder: (context, state) => const AdminFeaturePage(),
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
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
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
