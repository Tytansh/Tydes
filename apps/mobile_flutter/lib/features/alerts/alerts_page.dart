import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _AddAlertButton(
              onPressed: () async {
                final items = spots.valueOrNull;
                if (!context.mounted || items == null || items.isEmpty) return;
                await showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (context) => CreateAlertSheet(spots: items),
                );
              },
            ),
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
                    child: _AlertCard(
                      alert: alert,
                      spot: spot,
                      spots: spotItems,
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

class _AddAlertButton extends StatelessWidget {
  const _AddAlertButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_alert_outlined, size: 17, color: scheme.primary),
            const SizedBox(width: 6),
            Text(
              'Add alert',
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlertCard extends ConsumerWidget {
  const _AlertCard({
    required this.alert,
    required this.spot,
    required this.spots,
  });

  final AlertModel alert;
  final SpotModel? spot;
  final List<SpotModel> spots;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AlertSpotButton(
                    label: spot?.name ?? alert.spotId,
                    onPressed: spot == null
                        ? null
                        : () => context.push('/spot/${spot!.id}'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_alertStatusLine(alert)}\n${_alertSummary(alert)}\nNext check ${_formatAlertTime(alert.nextCheckAt)}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: () async {
                    await showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (context) =>
                          CreateAlertSheet(spots: spots, alert: alert),
                    );
                  },
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit alert',
                ),
                Switch(
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
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AlertSpotButton extends StatelessWidget {
  const _AlertSpotButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onPressed != null;

    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(9),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: enabled
                      ? scheme.outline.withValues(alpha: 0.55)
                      : scheme.outlineVariant,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.location_on_outlined,
                    size: 18,
                    color: enabled ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: enabled
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
  if (alert.tideEnabled &&
      alert.tideType != null &&
      alert.tideOffsetHours != null) {
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
