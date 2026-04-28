import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_models.dart';
import '../../core/notifications/notification_service.dart';
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
              final messenger = ScaffoldMessenger.of(context);
              final notifications = ref.read(notificationServiceProvider);
              final granted = await notifications.requestPermissions();
              if (!granted) {
                if (!context.mounted) return;
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Notifications are blocked. Turn them on in macOS Settings.',
                    ),
                  ),
                );
                return;
              }
              await notifications.showTestNotification();
              if (!context.mounted) return;
              messenger.showSnackBar(
                const SnackBar(
                  content: Text(
                    'Test notification sent. If no banner shows, check macOS notification settings for this app.',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.campaign_outlined),
            tooltip: 'Send test notification',
          ),
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
                          '${_alertStatusLine(alert)}\n${_alertSummary(alert)}\nNext check ${_formatAlertTime(alert.nextCheckAt)}',
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

String _alertStatusLine(AlertModel alert) {
  if (!alert.enabled) {
    return 'Alert turned off';
  }
  switch (alert.status) {
    case 'triggered':
      return alert.statusReason ?? 'Conditions match right now';
    case 'waiting':
      return alert.statusReason ?? 'Waiting on live data';
    case 'watching':
    default:
      return alert.statusReason ?? 'Watching conditions';
  }
}

String _alertSummary(AlertModel alert) {
  final parts = <String>[];
  if (alert.waveEnabled && alert.minWaveHeightM != null) {
    parts.add('Wave at least ${alert.minWaveHeightM}m');
  }
  if (alert.windEnabled && alert.maxWindKts != null) {
    parts.add('Wind less than ${alert.maxWindKts}kts');
  }
  if (alert.tideEnabled && alert.tideType != null && alert.tideOffsetHours != null) {
    final tideLabel = alert.tideType == 'high' ? 'high tide' : 'low tide';
    final offset = alert.tideOffsetHours!;
    if (offset == 0) {
      parts.add('At $tideLabel');
    } else if (offset < 0) {
      parts.add('${offset.abs()}h before $tideLabel');
    } else {
      parts.add('${offset.abs()}h after $tideLabel');
    }
  }
  if (parts.isEmpty) return 'Custom alert';
  return parts.join(' • ');
}

String _formatAlertTime(String timestamp) {
  final parsed = DateTime.tryParse(timestamp);
  if (parsed == null) {
    return timestamp;
  }
  final local = parsed.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour >= 12 ? 'PM' : 'AM';
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} $hour:$minute $period';
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
