import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import 'alert_monitor.dart';
import '../spots/spot_picker.dart';

const _tideOffsets = <int>[-3, -2, -1, 0, 1, 2, 3];

class CreateAlertSheet extends ConsumerStatefulWidget {
  const CreateAlertSheet({super.key, required this.spots});

  final List<SpotModel> spots;

  @override
  ConsumerState<CreateAlertSheet> createState() => _CreateAlertSheetState();
}

class _CreateAlertSheetState extends ConsumerState<CreateAlertSheet> {
  late String _spotId = widget.spots.first.id;
  bool _waveEnabled = true;
  double _minWaveHeightM = 1.2;
  bool _windEnabled = true;
  double _maxWindKts = 14;
  bool _tideEnabled = false;
  String _tideType = 'high';
  int _tideOffsetHours = 0;
  bool _submitting = false;

  @override
  Widget build(BuildContext context) {
    final favoriteSpotIds = ref.watch(favoriteSpotIdsProvider);
    final selectedSpot = spotForId(widget.spots, _spotId) ?? widget.spots.first;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Create alert',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            SpotPickerField(
              spots: widget.spots,
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
                            ? (_) => setState(() => _tideOffsetHours = offset)
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
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submitting ? null : _saveAlert,
                child: Text(_submitting ? 'Creating...' : 'Save alert'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveAlert() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _submitting = true);
    final alert = await ref.read(surfRepositoryProvider).createAlert(
          spotId: _spotId,
          waveEnabled: _waveEnabled,
          minWaveHeightM: _waveEnabled ? _minWaveHeightM : null,
          windEnabled: _windEnabled,
          maxWindKts: _windEnabled ? _maxWindKts.round() : null,
          tideEnabled: _tideEnabled,
          tideType: _tideEnabled ? _tideType : null,
          tideOffsetHours: _tideEnabled ? _tideOffsetHours : null,
        );
    ref.read(alertsRefreshKeyProvider.notifier).state++;
    await ref.read(alertMonitorProvider).checkNow();
    if (!mounted) return;
    if (alert.status == 'triggered') {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Alert is live now. Notification check sent.'),
        ),
      );
    }
    navigator.pop();
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
                Switch(
                  value: enabled,
                  onChanged: onChanged,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Opacity(
              opacity: enabled ? 1 : 0.45,
              child: IgnorePointer(
                ignoring: !enabled,
                child: child,
              ),
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
