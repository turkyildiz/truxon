import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'alarms.dart';
import 'api.dart';

/// Feature 6 (delivery side) — receive urgent dispatch pushes and turn the
/// ones flagged `alarm=1` (see the `notify` edge function) into DND-piercing
/// alarms via [Alarms]. Entirely optional at runtime: if Firebase isn't
/// configured on the build (no google-services.json), [PushService.init]
/// no-ops and the rest of the app works unchanged.

@pragma('vm:entry-point')
Future<void> firebaseBgHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {
    return;
  }
  if (message.data['alarm'] == '1') {
    await Alarms.showAlarm(
      message.notification?.title ?? 'Dispatch',
      message.notification?.body ?? 'Urgent message',
      payload: jsonEncode(message.data),
    );
  }
}

class PushService {
  static bool available = false;

  static Future<void> init(CompanionApi api) async {
    try {
      await Firebase.initializeApp();
      available = true;
    } catch (_) {
      available = false; // Firebase not wired on this build — skip push.
      return;
    }

    FirebaseMessaging.onBackgroundMessage(firebaseBgHandler);
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, sound: true, badge: false);

    FirebaseMessaging.onMessage.listen((m) {
      if (m.data['alarm'] == '1') {
        Alarms.showAlarm(
          m.notification?.title ?? 'Dispatch',
          m.notification?.body ?? 'Urgent message',
          payload: jsonEncode(m.data),
        );
      }
    });

    final platform = Platform.isIOS ? 'ios' : 'android';
    try {
      final token = await messaging.getToken();
      if (token != null) await api.registerPushToken(token, platform);
    } catch (_) {/* no token yet */}
    messaging.onTokenRefresh.listen((t) {
      api.registerPushToken(t, platform).catchError((_) {});
    });
  }
}
