import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_models.dart';
import '../../core/network/api_error_message.dart';
import '../../core/network/surf_repository.dart';
import 'alert_monitor.dart';
import 'alert_state.dart';
import 'alert_policy.dart';
import '../home/home_page.dart' show meProvider;
import '../spots/spot_picker.dart';

const _tideOffsets = <int>[-3, -2, -1, 0, 1, 2, 3];

class CreateAlertSheet extends ConsumerStatefulWidget {
  const CreateAlertSheet({super.key, required this.spots, this.alert});

  final List<SpotModel> spots;
  final AlertModel? alert;

  @override
  ConsumerState<CreateAlertSheet> createState() => _CreateAlertSheetState();
}

class _CreateAlertSheetState extends ConsumerState<CreateAlertSheet> {
  late String _spotId;
  late bool _waveEnabled;
  late double _minWaveHeightM;
  late bool _windEnabled;
  late double _maxWindKts;
  late bool _tideEnabled;
  late String _tideType;
  late int _tideOffsetHours;
  bool _submitting = false;
  String? _saveError;

  bool get _editing => widget.alert != null;

  @override
  void initState() {
    super.initState();
    final alert = widget.alert;
    final profile = ref.read(meProvider).valueOrNull;
    final preferred = profile?.premium == false
        ? profile?.freeLiveSpotId
        : null;
    _spotId =
        alert?.spotId ??
        (widget.spots.any((spot) => spot.id == preferred)
            ? preferred!
            : widget.spots.first.id);
    _waveEnabled = alert?.waveEnabled ?? true;
    _minWaveHeightM = (alert?.minWaveHeightM ?? 1.2).clamp(0.5, 3.0).toDouble();
    _windEnabled = alert?.windEnabled ?? true;
    _maxWindKts = (alert?.maxWindKts ?? 14)
        .toDouble()
        .clamp(6.0, 24.0)
        .toDouble();
    _tideEnabled = alert?.tideEnabled ?? true;
    _tideType = alert?.tideType ?? 'high';
    _tideOffsetHours = alert?.tideOffsetHours ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final favoriteSpotIds = ref.watch(favoriteSpotIdsProvider);
    final account = ref.watch(meProvider);
    final alerts = ref.watch(alertsProvider);
    final profile = account.hasError ? null : account.valueOrNull;
    final availableSpots = !_editing && profile != null && !profile.premium
        ? widget.spots
              .where((spot) => spot.id == profile.freeLiveSpotId)
              .toList()
        : widget.spots;
    if (!_editing && profile?.premium == false && availableSpots.isNotEmpty) {
      _spotId = availableSpots.first.id;
    }
    final mustActivate = widget.alert?.enabled ?? true;
    final activationBlock = !mustActivate
        ? null
        : alerts.hasError
        ? 'Refresh your alerts before saving changes.'
        : !alerts.hasValue
        ? 'Loading your alerts…'
        : alertActivationBlock(
            profile: profile,
            alerts: alerts.valueOrNull ?? const [],
            spotId: _spotId,
            editingAlertId: widget.alert?.id,
          );
    final selectedSpot = spotForId(widget.spots, _spotId) ?? widget.spots.first;

    return PopScope(
      canPop: !_submitting,
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: AbsorbPointer(
            absorbing: _submitting,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _editing ? 'Edit alert' : 'Create alert',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  profile?.premium == true
                      ? 'Premium · up to 10 active alerts across your spots.'
                      : 'Free · one active alert at your selected live-data spot, '
                            'including high or low tide.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                if (availableSpots.isNotEmpty)
                  SpotPickerField(
                    spots: availableSpots,
                    favoriteSpotIds: favoriteSpotIds,
                    selectedSpotId: _spotId,
                    labelText: 'Spot',
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _spotId = value);
                    },
                  ),
                const SizedBox(height: 18),
                _AlertRuleCard(
                  title: 'Wave',
                  enabled: _waveEnabled,
                  onChanged: (value) => setState(() => _waveEnabled = value),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Wave is at least ${_minWaveHeightM.toStringAsFixed(1)}m',
                      ),
                      Slider(
                        value: _minWaveHeightM,
                        min: 0.5,
                        max: 3,
                        divisions: 10,
                        label: _minWaveHeightM.toStringAsFixed(1),
                        onChanged: _waveEnabled
                            ? (value) => setState(() => _minWaveHeightM = value)
                            : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _AlertRuleCard(
                  title: 'Wind',
                  enabled: _windEnabled,
                  onChanged: (value) => setState(() => _windEnabled = value),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Wind is less than ${_maxWindKts.round()}kts'),
                      Slider(
                        value: _maxWindKts,
                        min: 6,
                        max: 24,
                        divisions: 9,
                        label: _maxWindKts.round().toString(),
                        onChanged: _windEnabled
                            ? (value) => setState(() => _maxWindKts = value)
                            : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _AlertRuleCard(
                  title: 'Tide window',
                  enabled: _tideEnabled,
                  onChanged: (value) => setState(() => _tideEnabled = value),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment<String>(
                            value: 'high',
                            label: Text('High tide'),
                          ),
                          ButtonSegment<String>(
                            value: 'low',
                            label: Text('Low tide'),
                          ),
                        ],
                        selected: {_tideType},
                        onSelectionChanged: _tideEnabled
                            ? (selection) =>
                                  setState(() => _tideType = selection.first)
                            : null,
                      ),
                      const SizedBox(height: 12),
                      Text(_tideWindowLabel(_tideType, _tideOffsetHours)),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _tideOffsets.map((offset) {
                          final selected = offset == _tideOffsetHours;
                          return ChoiceChip(
                            label: Text(_offsetChipLabel(offset)),
                            selected: selected,
                            onSelected: _tideEnabled
                                ? (_) =>
                                      setState(() => _tideOffsetHours = offset)
                                : null,
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${selectedSpot.name} • ${selectedSpot.area}, ${selectedSpot.region}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                if (activationBlock != null) ...[
                  Text(
                    activationBlock,
                    key: const ValueKey('alert-policy-message'),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () {
                          final router = GoRouter.of(context);
                          Navigator.of(context).pop();
                          router.go('/spots');
                        },
                        child: const Text('Choose free spot'),
                      ),
                      if (profile?.premium == false)
                        TextButton(
                          onPressed: () {
                            final router = GoRouter.of(context);
                            Navigator.of(context).pop();
                            router.push('/paywall');
                          },
                          child: const Text('Explore Premium'),
                        ),
                    ],
                  ),
                ],
                if (widget.alert != null && !widget.alert!.enabled) ...[
                  const Text('This alert will stay paused after saving.'),
                  const SizedBox(height: 10),
                ],
                if (_saveError != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _saveError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _submitting || activationBlock != null
                        ? null
                        : _saveAlert,
                    child: Text(
                      _submitting
                          ? (_editing ? 'Saving...' : 'Creating...')
                          : _saveError != null
                          ? 'Try again'
                          : (_editing ? 'Save changes' : 'Save alert'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _saveAlert() async {
    if (_submitting) return;
    if (widget.alert?.enabled ?? true) {
      final alerts = ref.read(alertsProvider);
      final block = !alerts.hasValue || alerts.hasError
          ? 'Refresh your alerts before saving changes.'
          : alertActivationBlock(
              profile: ref.read(meProvider).valueOrNull,
              alerts: alerts.valueOrNull!,
              spotId: _spotId,
              editingAlertId: widget.alert?.id,
            );
      if (block != null) {
        setState(() => _saveError = block);
        return;
      }
    }
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _submitting = true;
      _saveError = null;
    });
    final existing = widget.alert;
    try {
      await ref
          .read(alertsProvider.notifier)
          .save(
            alertId: existing?.id,
            spotId: _spotId,
            waveEnabled: _waveEnabled,
            minWaveHeightM: _waveEnabled ? _minWaveHeightM : null,
            windEnabled: _windEnabled,
            maxWindKts: _windEnabled ? _maxWindKts.round() : null,
            tideEnabled: _tideEnabled,
            tideType: _tideEnabled ? _tideType : null,
            tideOffsetHours: _tideEnabled ? _tideOffsetHours : null,
            enabled: existing?.enabled ?? true,
          );
      if (!mounted) return;
      // Notification delivery is separate from a confirmed save. A background
      // check must not turn a saved alert into an apparent failure or promise a
      // notification that wasn't delivered.
      unawaited(ref.read(alertMonitorProvider).checkNow());
      messenger.showSnackBar(
        SnackBar(content: Text(_editing ? 'Alert updated.' : 'Alert saved.')),
      );
      navigator.pop();
    } catch (error) {
      if (mounted) {
        setState(
          () => _saveError =
              'Could not save alert. ${friendlyErrorMessage(error)}',
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class _AlertRuleCard extends StatelessWidget {
  const _AlertRuleCard({
    required this.title,
    required this.enabled,
    required this.onChanged,
    required this.child,
  });

  final String title;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Switch(value: enabled, onChanged: onChanged),
              ],
            ),
            const SizedBox(height: 8),
            Opacity(
              opacity: enabled ? 1 : 0.45,
              child: IgnorePointer(ignoring: !enabled, child: child),
            ),
          ],
        ),
      ),
    );
  }
}

String _offsetChipLabel(int offset) {
  if (offset == 0) return 'At tide';
  if (offset < 0) return '${offset}h';
  return '+${offset}h';
}

String _tideWindowLabel(String tideType, int offset) {
  final tideLabel = tideType == 'high' ? 'High tide' : 'Low tide';
  if (offset == 0) return 'Alert at $tideLabel';
  if (offset < 0) return 'Alert ${offset.abs()}h before $tideLabel';
  return 'Alert ${offset.abs()}h after $tideLabel';
}

SpotModel? spotForId(List<SpotModel> spots, String spotId) {
  for (final spot in spots) {
    if (spot.id == spotId) {
      return spot;
    }
  }
  return null;
}
