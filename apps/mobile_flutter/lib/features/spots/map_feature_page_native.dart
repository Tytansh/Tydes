import 'package:flutter/widgets.dart';

import 'map_feature_module.dart';

class MapFeaturePage extends StatelessWidget {
  const MapFeaturePage({
    super.key,
    this.guest = false,
    this.initialSpotId,
    this.focusRevision = 0,
    this.embedded = false,
  });

  final bool guest;
  final String? initialSpotId;
  final int focusRevision;
  final bool embedded;

  @override
  Widget build(BuildContext context) => buildMapFeature(
    guest: guest,
    initialSpotId: initialSpotId,
    focusRevision: focusRevision,
    embedded: embedded,
  );
}
