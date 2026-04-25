import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../spots/spot_picker.dart';

class CreateAlertSheet extends ConsumerStatefulWidget {
  const CreateAlertSheet({super.key, required this.spots});

  final List<SpotModel> spots;

  @override
  ConsumerState<CreateAlertSheet> createState() => _CreateAlertSheetState();
}

class _CreateAlertSheetState extends ConsumerState<CreateAlertSheet> {
  late String _spotId = widget.spots.first.id;
  double _minWaveHeightM = 1.2;
  double _maxWindKts = 14;
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
          const SizedBox(height: 16),
          Text(
            'Alert when wave is at least ${_minWaveHeightM.toStringAsFixed(1)}m',
          ),
          Slider(
            value: _minWaveHeightM,
            min: 0.5,
            max: 3,
            divisions: 10,
            label: _minWaveHeightM.toStringAsFixed(1),
            onChanged: (value) => setState(() => _minWaveHeightM = value),
          ),
          Text('And wind is no more than ${_maxWindKts.round()}kts'),
          Slider(
            value: _maxWindKts,
            min: 6,
            max: 24,
            divisions: 9,
            label: _maxWindKts.round().toString(),
            onChanged: (value) => setState(() => _maxWindKts = value),
          ),
          const SizedBox(height: 8),
          Text(
            '${selectedSpot.name} • ${selectedSpot.area}, ${selectedSpot.region}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting
                ? null
                : () async {
                    final navigator = Navigator.of(context);
                    setState(() => _submitting = true);
                    await ref
                        .read(surfRepositoryProvider)
                        .createAlert(
                          spotId: _spotId,
                          minWaveHeightM: _minWaveHeightM,
                          maxWindKts: _maxWindKts.round(),
                        );
                    ref.read(alertsRefreshKeyProvider.notifier).state++;
                    if (!mounted) return;
                    navigator.pop();
                  },
            child: Text(_submitting ? 'Creating...' : 'Save alert'),
          ),
        ],
      ),
    );
  }
}

SpotModel? spotForId(List<SpotModel> spots, String spotId) {
  for (final spot in spots) {
    if (spot.id == spotId) {
      return spot;
    }
  }
  return null;
}
