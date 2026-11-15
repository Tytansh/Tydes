import 'package:flutter/material.dart';

/// Independent map layers, compact side by side or wrapped at narrow widths.
class MapLayerSwitches extends StatelessWidget {
  const MapLayerSwitches({
    super.key,
    required this.showSpots,
    required this.showEvents,
    required this.onSpotsChanged,
    required this.onEventsChanged,
    required this.spotsSwitchKey,
    required this.eventsSwitchKey,
  });

  final bool showSpots, showEvents;
  final ValueChanged<bool> onSpotsChanged, onEventsChanged;
  final Key spotsSwitchKey, eventsSwitchKey;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Wrap(
      alignment: WrapAlignment.end,
      spacing: 16,
      runSpacing: 4,
      children: [
        _layer('Show spots', showSpots, onSpotsChanged, spotsSwitchKey),
        _layer('Show events', showEvents, onEventsChanged, eventsSwitchKey),
      ],
    ),
  );

  Widget _layer(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
    Key switchKey,
  ) => MergeSemantics(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(width: 6),
        Switch(key: switchKey, value: value, onChanged: onChanged),
      ],
    ),
  );
}
