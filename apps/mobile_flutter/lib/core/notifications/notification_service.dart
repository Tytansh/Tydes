import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService();
});

class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<bool> initialize() async {
    if (_initialized) return true;
    const darwinSettings = DarwinInitializationSettings();
    const initializationSettings = InitializationSettings(
      iOS: darwinSettings,
      macOS: darwinSettings,
    );
    await _plugin.initialize(settings: initializationSettings);
    final granted = await _requestPermissions();
    _initialized = true;
    return granted;
  }

  Future<bool> requestPermissions() async {
    await initialize();
    return _requestPermissions();
  }

  Future<bool> _requestPermissions() async {
    final iosGranted = await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    final macGranted = await _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    return iosGranted ?? macGranted ?? true;
  }

  Future<void> showAlertTriggered({
    required int id,
    required String title,
    required String body,
  }) async {
    await initialize();
    const details = NotificationDetails(
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  Future<void> showTestNotification() async {
    await showAlertTriggered(
      id: 999001,
      title: 'Tydes test notification',
      body: 'If you can see this, local notifications are working.',
    );
  }
}
