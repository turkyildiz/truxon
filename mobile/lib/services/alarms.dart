import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../config.dart';

/// Feature 6 — alarms that ring through Do-Not-Disturb.
///
/// The `dispatch_alarm` channel plays its sound on the **alarm** audio stream
/// (`AudioAttributesUsage.alarm`) and posts as a **full-screen, alarm-category**
/// notification. Android exempts the alarm stream from Do-Not-Disturb, so an
/// urgent dispatch push wakes the screen and rings even when the tablet is
/// silenced — exactly what a driver needs for a new load. Used by the FCM
/// urgent-push handlers.
class Alarms {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    AppConfig.alarmChannelId,
    AppConfig.alarmChannelName,
    description: 'Urgent dispatch alerts and appointment alarms. Rings through silent/DND.',
    importance: Importance.max,
    playSound: true,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableVibration: true,
    enableLights: true,
  );

  static Future<void> init() async {
    if (_inited) return;
    _inited = true;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestSoundPermission: true,
      requestBadgePermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );

    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
  }

  /// Ask for notification + exact-alarm permissions (Android 13/14+).
  static Future<void> requestPermissions() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
    final ios = _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    await ios?.requestPermissions(alert: true, sound: true);
  }

  static AndroidNotificationDetails get _androidDetails =>
      AndroidNotificationDetails(
        AppConfig.alarmChannelId,
        AppConfig.alarmChannelName,
        channelDescription: _channel.description,
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true, // wake the screen even when locked
        audioAttributesUsage: AudioAttributesUsage.alarm,
        playSound: true,
        enableVibration: true,
        visibility: NotificationVisibility.public,
      );

  /// Ring an alarm right now (used by the FCM handlers for urgent dispatch).
  static Future<void> showAlarm(String title, String body, {String? payload}) async {
    await init();
    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      NotificationDetails(
        android: _androidDetails,
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
      payload: payload,
    );
  }
}
