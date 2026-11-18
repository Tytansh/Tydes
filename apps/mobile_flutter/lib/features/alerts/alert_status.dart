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

({String title, String detail}) _unavailableAlertCopy(AlertModel alert) {
  final reason = (alert.statusReason ?? '').trim().toLowerCase();
  if (reason.contains('spot not found')) {
    return (
      title: 'Spot unavailable',
      detail: 'The spot for this alert couldn’t be found.',
    );
  }
  if (reason.contains('an alert condition to be selected')) {
    return (
      title: 'Choose alert conditions',
      detail: 'Add conditions to finish setting up this alert.',
    );
  }
  final sources = reason.startsWith('waiting on ')
      ? reason
            .substring('waiting on '.length)
            .replaceFirst(RegExp(r'\.$'), '')
            .split(',')
            .map((source) => source.trim())
            .toList()
      : const <String>[];
  final onlyTide =
      sources.isNotEmpty &&
      sources.every(
        (source) => source == 'tide data' || source == 'tide events',
      );
  final onlyForecast =
      sources.isNotEmpty &&
      sources.every((source) => source == 'wave data' || source == 'wind data');
  if (onlyTide) {
    return (
      title: 'Tide check unavailable',
      detail:
          'Your alert is saved, but we couldn’t confirm the tide condition.',
    );
  }
  if (onlyForecast) {
    return (
      title: 'Forecast check unavailable',
      detail:
          'Your alert is saved, but we couldn’t confirm the forecast conditions.',
    );
  }
  return (
    title: 'Check unavailable',
    detail: 'Your alert is saved, but its conditions couldn’t be checked.',
  );
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
    final unavailableCopy = _unavailableAlertCopy(alert);
    final background = matched
        ? (dark ? const Color(0xFF123F37) : const Color(0xFFDFF7ED))
        : waiting
        ? theme.colorScheme.surfaceContainerLow
        : theme.colorScheme.surfaceContainer;
    final foreground = matched
        ? (dark ? const Color(0xFFB4F6D6) : const Color(0xFF124B37))
        : theme.colorScheme.onSurface;
    final secondary = waiting ? theme.colorScheme.onSurfaceVariant : foreground;
    final border = matched
        ? (dark ? const Color(0xFF4CB58D) : const Color(0xFF7DC8A5))
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
        unavailableCopy.title,
        unavailableCopy.detail,
        Icons.info_outline_rounded,
      ),
      SurfAlertState.off => (
        'Alert paused',
        switch (alert.pauseReason) {
          'spot_access' =>
            'This alert needs live data at its spot. Select it as '
                'your free spot or use Premium, then turn the alert back on.',
          'active_limit' =>
            'Your active alert limit was reached. Pause another '
                'alert before turning this one back on.',
          _ => 'Turn this alert on to watch for your conditions.',
        },
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
      padding: EdgeInsets.all(waiting ? 12 : (widget.compact ? 16 : 20)),
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
                padding: EdgeInsets.all(waiting ? 6 : 9),
                decoration: BoxDecoration(
                  color: waiting
                      ? theme.colorScheme.primary.withValues(alpha: 0.08)
                      : foreground.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: waiting ? 18 : 25,
                  color: waiting ? secondary : foreground,
                ),
              ),
              SizedBox(width: waiting ? 10 : 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: waiting ? 16 : (widget.compact ? 20 : 23),
                        fontWeight: waiting ? FontWeight.w700 : FontWeight.w800,
                        color: foreground,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      detail,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: secondary,
                        fontSize: waiting ? 13 : null,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: waiting ? 10 : 16),
          Text(
            alertConditionsSummary(alert),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: secondary,
              height: 1.5,
              fontSize: waiting ? 13 : null,
              fontWeight: waiting ? FontWeight.w500 : FontWeight.w700,
            ),
          ),
          SizedBox(height: waiting ? 8 : 10),
          Wrap(
            spacing: 16,
            runSpacing: 5,
            children: [
              if (alert.lastEvaluatedAt != null)
                Text(
                  'Checked ${formatAlertCheckTime(alert.lastEvaluatedAt!)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: secondary),
                ),
              if (alert.enabled)
                Text(
                  'Next check ${formatAlertCheckTime(alert.nextCheckAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: secondary),
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
