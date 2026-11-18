import '../../core/network/api_models.dart';

int activeAlertLimit(UserProfile profile) => profile.premium ? 10 : 1;

/// UI guidance only. The API independently enforces access and active limits.
String? alertActivationBlock({
  required UserProfile? profile,
  required Iterable<AlertModel> alerts,
  required String spotId,
  String? editingAlertId,
}) {
  if (profile == null) return 'Wait for your account to load and try again.';
  if (!profile.emailVerified) {
    return 'Verify your email before creating alerts.';
  }
  if (!profile.canAccessLiveForecast(spotId)) {
    return profile.freeLiveSpotId == null
        ? 'Choose your free live-data spot on the Spots page first.'
        : 'Free alerts are available only at your selected live-data spot. '
              'Choose this as your free spot or use Premium.';
  }
  final active = alerts
      .where((alert) => alert.enabled && alert.id != editingAlertId)
      .length;
  final limit = activeAlertLimit(profile);
  if (active >= limit) {
    return profile.premium
        ? 'You have 10 active alerts. Pause an alert before adding another.'
        : 'Your free active alert is already in use. Pause it first, or use '
              'Premium for up to 10 active alerts.';
  }
  return null;
}
