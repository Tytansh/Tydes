import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';
import '../social/social_profile.dart';
import '../alerts/alerts_page.dart';
import '../settings/settings_page.dart';
import '../spots/spots_map_page.dart';
import '../trips/trips_page.dart';

class AppScaffold extends ConsumerWidget {
  const AppScaffold({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final profile = me.valueOrNull;

    if (me.isLoading) {
      return const _AppAuthGate(message: 'Loading your account...');
    }

    if (me.hasError || profile == null) {
      _sendToLogin(context, ref);
      return const _AppAuthGate(message: 'Taking you to sign in...');
    }

    if (_needsProfileSetup(profile)) {
      _sendToLogin(context, ref, clearSession: true);
      return const _AppAuthGate(message: 'Taking you to sign in...');
    }

    final tab = ref.watch(currentTabProvider);
    final pages = ref.watch(shellPagesProvider);
    ref.watch(socialRelationshipHydrationProvider);
    final strings = AppStrings.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final desktopWeb = kIsWeb && constraints.maxWidth >= 980;
        if (desktopWeb) {
          const desktopPages = <Widget>[
            HomePage(),
            SpotsMapPage(),
            TripsPage(),
            AlertsPage(),
            SettingsPage(),
          ];
          return Scaffold(
            body: Row(
              children: [
                _DesktopNavigation(
                  selectedIndex: tab,
                  strings: strings,
                  onDestinationSelected: (index) =>
                      ref.read(currentTabProvider.notifier).state = index,
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  child: SafeArea(
                    left: false,
                    child: IndexedStack(index: tab, children: desktopPages),
                  ),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          body: SafeArea(
            child: IndexedStack(index: tab, children: pages),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (index) =>
                ref.read(currentTabProvider.notifier).state = index,
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.home_outlined),
                label: strings.home,
              ),
              NavigationDestination(
                icon: const Icon(Icons.waves_outlined),
                label: strings.spots,
              ),
              NavigationDestination(
                icon: const Icon(Icons.luggage_outlined),
                label: strings.trips,
              ),
              NavigationDestination(
                icon: const Icon(Icons.notifications_active_outlined),
                label: strings.alerts,
              ),
              NavigationDestination(
                icon: const Icon(Icons.person_outline),
                selectedIcon: const Icon(Icons.person),
                label: strings.profile,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DesktopNavigation extends StatelessWidget {
  const _DesktopNavigation({
    required this.selectedIndex,
    required this.strings,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final AppStrings strings;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      extended: true,
      minExtendedWidth: 236,
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      groupAlignment: -1,
      backgroundColor: const Color(0xFF174A4F),
      indicatorColor: const Color(0xFFC9F1ED),
      selectedIconTheme: const IconThemeData(color: Color(0xFF174A4F)),
      selectedLabelTextStyle: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w800,
      ),
      unselectedIconTheme: const IconThemeData(color: Color(0xFFD0E2E1)),
      unselectedLabelTextStyle: const TextStyle(
        color: Color(0xFFD0E2E1),
        fontWeight: FontWeight.w700,
      ),
      leading: const SizedBox(
        width: 236,
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, 24, 12, 36),
          child: Row(
            children: [
              _DesktopBrandMark(),
              SizedBox(width: 12),
              Text(
                'Tydes',
                style: TextStyle(
                  color: Color(0xFFF4FAF9),
                  fontFamily: 'Sora',
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.65,
                ),
              ),
            ],
          ),
        ),
      ),
      destinations: [
        NavigationRailDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home_rounded),
          label: Text(strings.home),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.map_outlined),
          selectedIcon: const Icon(Icons.map_rounded),
          label: Text(strings.spots),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.luggage_outlined),
          selectedIcon: const Icon(Icons.luggage_rounded),
          label: Text(strings.trips),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.notifications_active_outlined),
          selectedIcon: const Icon(Icons.notifications_active_rounded),
          label: Text(strings.alerts),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.person_outline),
          selectedIcon: const Icon(Icons.person),
          label: Text(strings.profile),
        ),
      ],
    );
  }
}

class _DesktopBrandMark extends StatelessWidget {
  const _DesktopBrandMark();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Image.asset(
        'assets/branding/tydes-wave-blue-256.png',
        width: 52,
        height: 52,
        fit: BoxFit.cover,
      ),
    );
  }
}

bool _needsProfileSetup(UserProfile profile) {
  return profile.displayName.trim().isEmpty ||
      profile.handle.trim().isEmpty ||
      profile.surfSkill.trim().isEmpty;
}

void _sendToLogin(
  BuildContext context,
  WidgetRef ref, {
  bool clearSession = false,
}) {
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (!context.mounted) return;
    if (clearSession) {
      await ref.read(surfRepositoryProvider).logout();
    }
    ref.invalidate(meProvider);
    ref.invalidate(dashboardProvider);
    ref.invalidate(homeAdsProvider);
    if (context.mounted) {
      context.go('/login');
    }
  });
}

class _AppAuthGate extends StatelessWidget {
  const _AppAuthGate({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 34,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: const TextStyle(
                color: Color(0xFF5D686C),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
