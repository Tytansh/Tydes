import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/l10n/app_strings.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';
import '../social/social_profile.dart';

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

    return Scaffold(
      body: SafeArea(child: pages[tab]),
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
