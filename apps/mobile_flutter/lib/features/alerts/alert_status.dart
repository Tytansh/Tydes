import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/network/api_models.dart';

enum SurfAlertState { matched, watching, waiting, off, updateDue }

/// A matched badge is only current until the next server evaluation is due.
/// This presents server results; it never calculates a match from forecasts.
SurfAlertState surfAlertState(AlertModel alert, {DateTime? now}) {
  if (!alert.enabled) return SurfAlertState.off;
  if (alert.status != 'triggered') {
    return alert.status == 'waiting'
        ? SurfAlertState.waiting
        : SurfAlertState.watching;
  }
  final clock = now ?? DateTime.now();
  final evaluated = DateTime.tryParse(alert.lastEvaluatedAt ?? '');
  final nextCheck = DateTime.tryParse(alert.nextCheckAt);
  if (evaluated == null ||
      nextCheck == null ||
      !nextCheck.isAfter(clock) ||
      evaluated.isAfter(clock.add(const Duration(minutes: 5))) ||
      evaluated.isAfter(nextCheck) ||
      !clock.isBefore(evaluated.add(const Duration(hours: 4, minutes: 5)))) {
    return SurfAlertState.updateDue;
  }
  return SurfAlertState.matched;
}

String alertConditionsSummary(AlertModel alert) {
  final parts = <String>[];
  if (alert.waveEnabled && alert.minWaveHeightM != null) {
    final height = alert.minWaveHeightM!;
    final label = height == height.roundToDouble()
        ? height.toStringAsFixed(0)
        : height.toString();
    parts.add('Wave at least $label m');
  }
  if (alert.windEnabled && alert.maxWindKts != null) {
    parts.add('Wind less than ${alert.maxWindKts} kts');
  }
  if (alert.tideEnabled &&
      alert.tideType != null &&
      alert.tideOffsetHours != null) {
    final tide = alert.tideType == 'high' ? 'high tide' : 'low tide';
    final offset = alert.tideOffsetHours!;
    parts.add(
      offset == 0
          ? 'At $tide'
          : '${offset.abs()}h ${offset < 0 ? 'before' : 'after'} $tide',
    );
  }
  return parts.isEmpty ? 'Custom alert conditions' : parts.join('  •  ');
}

String formatAlertCheckTime(String timestamp) {
  final parsed = DateTime.tryParse(timestamp);
  if (parsed == null) return 'Unavailable';
  final local = parsed.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour >= 12 ? 'PM' : 'AM';
  return '${local.day}/${local.month} at $hour:$minute $period';
}

/// Shared between the alerts list and the relevant spot's forecast page.
class AlertStatusBanner extends StatefulWidget {
  const AlertStatusBanner({
    super.key,
    required this.alert,
    this.now,
    this.compact = false,
  });

  final AlertModel alert;
  final DateTime? now;
  final bool compact;

  @override
  State<AlertStatusBanner> createState() => _AlertStatusBannerState();
}

class _AlertStatusBannerState extends State<AlertStatusBanner> {
  Timer? _expiry;

  @override
  void initState() {
    super.initState();
    _scheduleExpiry();
  }

  @override
  void didUpdateWidget(covariant AlertStatusBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleExpiry();
  }

  void _scheduleExpiry() {
    _expiry?.cancel();
    if (widget.now != null ||
        surfAlertState(widget.alert) != SurfAlertState.matched) {
      return;
    }
    final nextCheck = DateTime.parse(widget.alert.nextCheckAt);
    final maxAge = DateTime.parse(
      widget.alert.lastEvaluatedAt!,
    ).add(const Duration(hours: 4, minutes: 5));
    final expiresAt = nextCheck.isBefore(maxAge) ? nextCheck : maxAge;
    _expiry = Timer(expiresAt.difference(DateTime.now()), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final alert = widget.alert;
    final status = surfAlertState(alert, now: widget.now);
    final matched = status == SurfAlertState.matched;
    final waiting = status == SurfAlertState.waiting;
    final background = matched
        ? (dark ? const Color(0xFF123F37) : const Color(0xFFDFF7ED))
        : waiting
        ? (dark ? const Color(0xFF3B3425) : const Color(0xFFFFF3DB))
        : theme.colorScheme.surfaceContainer;
    final foreground = matched
        ? (dark ? const Color(0xFFB4F6D6) : const Color(0xFF124B37))
        : waiting
        ? (dark ? const Color(0xFFFFDB94) : const Color(0xFF694A12))
        : theme.colorScheme.onSurface;
    final border = matched
        ? (dark ? const Color(0xFF4CB58D) : const Color(0xFF7DC8A5))
        : waiting
        ? (dark ? const Color(0xFF817047) : const Color(0xFFE8CE98))
        : theme.colorScheme.outlineVariant;
    final (title, detail, icon) = switch (status) {
      SurfAlertState.matched => (
        'Surf alert matched',
        'Your conditions match the latest forecast check.',
        Icons.notifications_active_rounded,
      ),
      SurfAlertState.watching => (
        'Watching conditions',
        alert.statusReason ?? 'We’re watching for your chosen conditions.',
        Icons.radar_rounded,
      ),
      SurfAlertState.waiting => (
        'Waiting for data',
        alert.statusReason ?? 'Live data is unavailable for this check.',
        Icons.cloud_off_outlined,
      ),
      SurfAlertState.off => (
        'Alert paused',
        'Turn this alert on to watch for your conditions.',
        Icons.notifications_paused_outlined,
      ),
      SurfAlertState.updateDue => (
        'Update due',
        'Previously matched. Refresh alerts for the latest check.',
        Icons.update_rounded,
      ),
    };

    return Container(
      key: ValueKey('alert-status-${status.name}'),
      width: double.infinity,
      padding: EdgeInsets.all(widget.compact ? 16 : 20),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border, width: matched ? 1.5 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: foreground.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 25, color: foreground),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: widget.compact ? 20 : 23,
                        fontWeight: FontWeight.w800,
                        color: foreground,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      detail,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            alertConditionsSummary(alert),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: foreground,
              height: 1.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 5,
            children: [
              if (alert.lastEvaluatedAt != null)
                Text(
                  'Checked ${formatAlertCheckTime(alert.lastEvaluatedAt!)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: foreground),
                ),
              if (alert.enabled)
                Text(
                  'Next check ${formatAlertCheckTime(alert.nextCheckAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: foreground),
                ),
            ],
          ),
          if (matched) ...[
            const SizedBox(height: 10),
            Text(
              'Forecast guidance only · Check local conditions and hazards.',
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ],
        ],
      ),
    );
  }
}
