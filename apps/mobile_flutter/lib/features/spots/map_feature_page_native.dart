import 'package:flutter/widgets.dart';

import 'map_feature_module.dart';

class MapFeaturePage extends StatelessWidget {
  const MapFeaturePage({super.key, this.guest = false, this.initialSpotId});

  final bool guest;
  final String? initialSpotId;

  @override
  Widget build(BuildContext context) =>
      buildMapFeature(guest: guest, initialSpotId: initialSpotId);
}
