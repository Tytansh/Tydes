import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_models.dart';
import 'surf_repository.dart';

/// Static authenticated spot guides shared across tab navigation. Forecasts,
/// favorites and guest previews keep their own authorization/freshness rules.
/// Existing tab names alias this exact provider so any explicit refresh still
/// invalidates the one catalog. Authentication changes invalidate it separately.
final spotCatalogProvider = FutureProvider<List<SpotModel>>((ref) {
  ref.watch(accountVerificationRefreshKeyProvider);
  return ref.watch(surfRepositoryProvider).fetchSpots();
});
