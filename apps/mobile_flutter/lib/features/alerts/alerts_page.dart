import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error_message.dart';
import '../../core/network/api_models.dart';
import 'alert_state.dart';
import 'alert_status.dart';
import 'create_alert_sheet.dart';
import '../spots/spots_page.dart';

export 'alert_state.dart' show alertsProvider;

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
            tooltip: 'Refresh alerts',
            onPressed: () => ref.invalidate(alertsProvider),
            icon: const Icon(Icons.refresh),
          ),
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
                  return _AlertRow(
                    key: ValueKey(alert.id),
                    alert: alert,
                    spot: spot,
                    spots: spotItems,
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const SizedBox.shrink(),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  friendlyLoadErrorMessage(error, label: 'alerts'),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => ref.invalidate(alertsProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
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

class _AlertRow extends ConsumerStatefulWidget {
  const _AlertRow({
    super.key,
    required this.alert,
    required this.spot,
    required this.spots,
  });

  final AlertModel alert;
  final SpotModel? spot;
  final List<SpotModel> spots;

  @override
  ConsumerState<_AlertRow> createState() => _AlertRowState();
}

class _AlertRowState extends ConsumerState<_AlertRow> {
  bool _busy = false;
  bool _editing = false;

  void _showFailure(Object error, String operation, VoidCallback retry) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Could not $operation alert. ${friendlyErrorMessage(error)}',
        ),
        action: SnackBarAction(label: 'Retry', onPressed: retry),
      ),
    );
  }

  Future<bool> _delete() async {
    if (!mounted || _busy) return false;
    setState(() => _busy = true);
    try {
      await ref.read(alertsProvider.notifier).delete(widget.alert.id);
      return true;
    } catch (error) {
      if (mounted) {
        _showFailure(error, 'delete', () {
          _delete();
        });
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setEnabled(bool enabled) async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(alertsProvider.notifier)
          .setEnabled(widget.alert.id, enabled);
    } catch (error) {
      if (mounted) {
        _showFailure(error, 'update', () {
          _setEnabled(enabled);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final alert = widget.alert;
    final spot = widget.spot;
    return Dismissible(
      key: ValueKey('dismiss-${alert.id}'),
      direction: _busy ? DismissDirection.none : DismissDirection.endToStart,
      confirmDismiss: (_) => _delete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: const Color(0xFFCF4A3B),
          borderRadius: BorderRadius.circular(24),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _AlertSpotButton(
                      label: spot?.name ?? alert.spotId,
                      onPressed: spot == null
                          ? null
                          : () => context.push('/spot/${spot.id}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            setState(() {
                              _busy = true;
                              _editing = true;
                            });
                            try {
                              await showModalBottomSheet<void>(
                                context: context,
                                isScrollControlled: true,
                                builder: (context) => CreateAlertSheet(
                                  spots: widget.spots,
                                  alert: alert,
                                ),
                              );
                            } finally {
                              if (mounted) {
                                setState(() {
                                  _busy = false;
                                  _editing = false;
                                });
                              }
                            }
                          },
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Edit alert',
                  ),
                  Switch(
                    value: alert.enabled,
                    onChanged: _busy ? null : _setEnabled,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              AlertStatusBanner(alert: alert),
              if (_busy && !_editing) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(),
              ],
            ],
          ),
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
