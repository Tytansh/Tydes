import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/surf_repository.dart';

final plansProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchPlans(),
);

class PaywallPage extends ConsumerWidget {
  const PaywallPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plans = ref.watch(plansProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Premium plans')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: plans.when(
          data: (items) => ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final plan = items[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plan.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '\$${plan.priceUsdMonthly.toStringAsFixed(2)} / month',
                      ),
                      const SizedBox(height: 12),
                      ...plan.features.map((feature) => Text(feature)),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: () {},
                        child: Text(
                          plan.id == 'premium' ? 'Upgrade' : 'Current',
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) =>
              Center(child: Text('Could not load plans: $error')),
        ),
      ),
    );
  }
}
