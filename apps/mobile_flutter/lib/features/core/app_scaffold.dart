import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../core/l10n/app_strings.dart';

class AppScaffold extends ConsumerWidget {
  const AppScaffold({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(currentTabProvider);
    final strings = AppStrings.of(context);

    return Scaffold(
      body: SafeArea(child: shellPages[tab]),
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
