import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../core/network/surf_repository.dart';
import '../social/social_feed.dart';

final dashboardProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchDashboard(),
);
final meProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchMe(),
);
final homeAdsProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchAds(),
);

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(meProvider);
    final spots = ref.watch(travelFeedSpotsProvider);
    final spotItems = spots.valueOrNull ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Travel feed'),
        backgroundColor: Theme.of(context).colorScheme.surface,
        surfaceTintColor: Theme.of(context).colorScheme.surface,
        actions: [
          TextButton(
            onPressed: () => ref.read(currentTabProvider.notifier).state = 4,
            child: Text(
              user.maybeWhen(
                data: (profile) => profile.displayName.split(' ').first,
                orElse: () => 'Profile',
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () => showCreatePostSheet(context, spotItems),
            icon: const Icon(Icons.add),
            label: const Text('Post'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const TravelFeedSection(showHeader: false),
        ],
      ),
    );
  }
}
