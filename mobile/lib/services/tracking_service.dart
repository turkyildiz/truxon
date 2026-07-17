import 'dart:async';
import 'dart:convert';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'session_store.dart';

/// ALWAYS-ON background GPS (Feature 4).
///
/// Phase 1 sampled location with a Dart [Timer], which Android freezes the
/// moment the app is backgrounded or the screen turns off. This replaces it
/// with a proper Android **foreground service** (persistent notification) via
/// flutter_foreground_task. The service:
///   * keeps a dedicated isolate alive when backgrounded / screen-off,
///   * restarts itself after a reboot (`autoRunOnBoot`),
///   * samples GPS every 60s and flushes to `ingest_vehicle_positions`,
///   * durably queues fixes in SharedPreferences so nothing is lost if the
///     network or the auth token is briefly unavailable.
///
/// [TruxTrackingService] is the UI-side controller (start/stop + permissions).
/// [_TrackingHandler] runs inside the service isolate.

// ---------------------------------------------------------------------------
// Background isolate entry point + handler.
// ---------------------------------------------------------------------------

@pragma('vm:entry-point')
void trackingCallback() {
  FlutterForegroundTask.setTaskHandler(_TrackingHandler());
}

class _TrackingHandler extends TaskHandler {
  final List<Map<String, dynamic>> _queue = [];

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _loadQueue();
    // Take one fix immediately so the map lights up without waiting a minute.
    await _sample();
  }

  // Called on the interval configured in ForegroundTaskOptions.
  @override
  void onRepeatEvent(DateTime timestamp) {
    _sample();
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _persistQueue();
  }

  Future<void> _sample() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _queue.add({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'recorded_at': DateTime.now().toUtc().toIso8601String(),
        'speed_mps': pos.speed,
        'heading_deg': pos.heading,
        'accuracy_m': pos.accuracy,
      });
      // Cap the durable queue so a long offline stretch can't grow unbounded.
      if (_queue.length > 5000) _queue.removeRange(0, _queue.length - 5000);
      await _persistQueue();
      await _flush();
      // Surface state in the persistent notification.
      final now = DateTime.now();
      final hh = now.hour.toString().padLeft(2, '0');
      final mm = now.minute.toString().padLeft(2, '0');
      FlutterForegroundTask.updateService(
        notificationTitle: 'Trux — sharing location',
        notificationText: 'Last fix $hh:$mm · ${_queue.length} queued',
      );
    } catch (_) {
      // Permission/location hiccup — try again next tick.
    }
  }

  Future<void> _flush() async {
    if (_queue.isEmpty) return;
    final token = await SessionStore.accessToken();
    if (token == null) return; // stale token: keep queuing, upload later.
    final batch = List<Map<String, dynamic>>.from(_queue.take(100));
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.supabaseUrl}/rest/v1/rpc/ingest_vehicle_positions'),
        headers: {
          'apikey': AppConfig.supabaseAnonKey,
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'p_points': batch}),
      );
      if (res.statusCode >= 200 && res.statusCode < 300) {
        _queue.removeRange(0, batch.length);
        await _persistQueue();
      }
      // 401/403 => token stale: leave the queue, it flushes on next refresh.
    } catch (_) {
      // Network down — keep the queue for the next tick.
    }
  }

  Future<void> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(SessionStore.kGpsQueue);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List;
      _queue
        ..clear()
        ..addAll(list.map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (_) {/* corrupt cache — ignore */}
  }

  Future<void> _persistQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(SessionStore.kGpsQueue, jsonEncode(_queue));
  }
}

// ---------------------------------------------------------------------------
// UI-side controller.
// ---------------------------------------------------------------------------

class TruxTrackingService {
  static final TruxTrackingService instance = TruxTrackingService._();
  TruxTrackingService._();

  bool _inited = false;

  /// Configure the foreground service. Safe to call more than once.
  void init() {
    if (_inited) return;
    _inited = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'trux_tracking',
        channelName: 'Location sharing',
        channelDescription: 'Shares your position with dispatch while on duty.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(
          AppConfig.gpsInterval.inMilliseconds,
        ),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Location (while-in-use → always) + notification permission. Returns true
  /// when we have at least foreground location; background is best-effort.
  Future<bool> ensurePermissions() async {
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    final notif = await FlutterForegroundTask.checkNotificationPermission();
    if (notif != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
      return false;
    }
    // Ask for "Allow all the time" so tracking survives backgrounding. Android
    // requires this as a second, separate prompt after while-in-use is granted.
    if (perm == LocationPermission.whileInUse) {
      await Geolocator.requestPermission();
    }
    return true;
  }

  Future<bool> isRunningServiceAsync() => FlutterForegroundTask.isRunningService;

  /// Start or stop always-on tracking. Persists the choice so the boot handler
  /// knows whether to resume after a reboot.
  Future<bool> setTracking(bool on) async {
    init();
    await SessionStore.setTrackingFlag(on);
    if (on) {
      final ok = await ensurePermissions();
      if (!ok) return false;
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.restartService();
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 42,
          notificationTitle: 'Trux — sharing location',
          notificationText: 'Dispatch can see the truck. Always on.',
          callback: trackingCallback,
        );
      }
      return true;
    } else {
      await FlutterForegroundTask.stopService();
      return true;
    }
  }
}
