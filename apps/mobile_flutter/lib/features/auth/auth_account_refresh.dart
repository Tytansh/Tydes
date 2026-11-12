import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/surf_repository.dart';
import '../alerts/alert_state.dart';
import '../home/home_page.dart';
import '../social/direct_messages_page.dart';
import '../social/inbox_badges.dart';
import '../social/notifications_page.dart';
import '../social/social_profile.dart';
import '../spots/spot_detail_page.dart';
import '../spots/spots_page.dart';

/// Account-scoped caches must not survive sign-in, sign-out, or verification.
void refreshAuthenticatedAccount(WidgetRef ref) {
  ref.read(inboxForegroundAccountProvider.notifier).state = null;
  ref.invalidate(inboxUnreadCountsProvider);
  ref.invalidate(directMessageThreadsProvider);
  ref.invalidate(socialNotificationsProvider);
  ref.invalidate(alertsProvider);
  ref.invalidate(meProvider);
  ref.invalidate(dashboardProvider);
  ref.invalidate(homeAdsProvider);
  ref.invalidate(spotForecastsBySpotProvider);
  ref.invalidate(spotCardForecastProvider);
  ref.invalidate(spotTideProvider);
  ref.invalidate(spotSurfWindowProvider);
  ref.invalidate(spotDetailBundleProvider);
  ref.invalidate(favoriteSpotIdsProvider);
  ref.invalidate(followedUserIdsProvider);
  ref.invalidate(followerUserIdsProvider);
  ref.invalidate(blockedUserIdsProvider);
  ref.invalidate(hiddenFollowingUserIdsProvider);
  ref.invalidate(hiddenFollowerUserIdsProvider);
  ref.invalidate(socialRelationshipHydrationProvider);
  ref.read(socialRefreshKeyProvider.notifier).state++;
}
