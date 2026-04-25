import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import 'create_alert_sheet.dart';
import '../spots/spots_page.dart';

final alertsProvider = FutureProvider((ref) {
  ref.watch(alertsRefreshKeyProvider);
  return ref.watch(surfRepositoryProvider).fetchAlerts();
});

class AlertsPage extends ConsumerWidget {
  const AlertsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsProvider);
    final spots = ref.watch(spotsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Alerts'),
        actions: [
          IconButton(
            onPressed: () async {
              final items = spots.valueOrNull;
              if (!context.mounted || items == null || items.isEmpty) return;
              await showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (context) => CreateAlertSheet(spots: items),
              );
            },
            icon: const Icon(Icons.add_alert_outlined),
            tooltip: 'Create alert',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: alerts.when(
          data: (items) => spots.when(
            data: (spotItems) {
              if (items.isEmpty) {
                return _EmptyAlertsState(spots: spotItems);
              }
              return ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final alert = items[index];
                  final spot = spotForId(spotItems, alert.spotId);
                  return Dismissible(
                    key: ValueKey(alert.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      decoration: BoxDecoration(
                        color: const Color(0xFFCF4A3B),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Icon(
                        Icons.delete_outline,
                        color: Colors.white,
                      ),
                    ),
                    onDismissed: (_) async {
                      await ref
                          .read(surfRepositoryProvider)
                          .deleteAlert(alert.id);
                      ref.read(alertsRefreshKeyProvider.notifier).state++;
                    },
                    child: Card(
                      child: SwitchListTile(
                        value: alert.enabled,
                        onChanged: (enabled) async {
                          await ref
                              .read(surfRepositoryProvider)
                              .updateAlertEnabled(
                                alertId: alert.id,
                                enabled: enabled,
                              );
                          ref.read(alertsRefreshKeyProvider.notifier).state++;
                        },
                        title: Text(spot?.name ?? alert.spotId),
                        subtitle: Text(
                          'Min wave ${alert.minWaveHeightM}m, max wind ${alert.maxWindKts}kts\nNext check ${alert.nextCheckAt}',
                        ),
                      ),
                    ),
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const SizedBox.shrink(),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) =>
              Center(child: Text('Could not load alerts: $error')),
        ),
      ),
    );
  }
}

class _EmptyAlertsState extends StatelessWidget {
  const _EmptyAlertsState({required this.spots});

  final List<SpotModel> spots;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.notifications_active_outlined, size: 34),
              const SizedBox(height: 12),
              Text(
                'No alerts yet',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'Create one for a favorite break and we’ll keep an eye on wave height and wind.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (context) => CreateAlertSheet(spots: spots),
                ),
                icon: const Icon(Icons.add_alert_outlined),
                label: const Text('Create alert'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
