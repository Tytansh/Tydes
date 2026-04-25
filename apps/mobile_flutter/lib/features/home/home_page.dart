import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../core/l10n/app_strings.dart';
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
    final strings = AppStrings.of(context);
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
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF173F3F), Color(0xFF7CB7A8)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.appName,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Post the session. Find the crew.',
                  style: Theme.of(
                    context,
                  ).textTheme.headlineMedium?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Photos, short clips, plans, and travel notes from surfers nearby.',
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const TravelFeedSection(showHeader: false),
        ],
      ),
    );
  }
}
