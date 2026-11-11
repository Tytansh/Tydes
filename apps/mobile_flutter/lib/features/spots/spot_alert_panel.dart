import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../alerts/alert_state.dart';
import '../alerts/alert_status.dart';

/// Reuses the account's confirmed alert list, not a new forecast per spot.
class SpotAlertPanel extends ConsumerWidget {
  const SpotAlertPanel({
    super.key,
    required this.spotId,
    required this.onManage,
  });

  final String spotId;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsProvider);
    return alerts.when(
      data: (items) {
        final here = items.where((alert) => alert.spotId == spotId).toList();
        if (here.isEmpty) return const SizedBox.shrink();
        return Padding(
          key: const ValueKey('spot-alert-panel'),
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      here.length == 1 ? 'Your surf alert' : 'Your surf alerts',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onManage,
                    child: const Text('Manage alerts'),
                  ),
                ],
              ),
              for (final alert in here)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: AlertStatusBanner(alert: alert, compact: true),
                ),
            ],
          ),
        );
      },
      // Alert loading must never block the spot guide or forecast desk.
      loading: () => const SizedBox.shrink(),
      error: (_, _) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Card(
          child: ListTile(
            leading: const Icon(Icons.notifications_off_outlined),
            title: const Text('Alert status unavailable'),
            trailing: TextButton(
              onPressed: () => ref.invalidate(alertsProvider),
              child: const Text('Retry'),
            ),
          ),
        ),
      ),
    );
  }
}
