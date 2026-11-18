import 'package:flutter/widgets.dart';

import '../guest/guest_explore_page.dart';
import 'spots_map_page.dart';

// Keep both entrypoints behind one web boundary so flutter_map and latlong2
// are not pulled into the initial login/feed bundle through the guest route.
Widget buildMapFeature({
  bool guest = false,
  String? initialSpotId,
  int focusRevision = 0,
  bool embedded = false,
}) => guest
    ? const GuestExplorePage()
    : SpotsMapPage(
        initialSpotId: initialSpotId,
        focusRevision: focusRevision,
        embedded: embedded,
      );
