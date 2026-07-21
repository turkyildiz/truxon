import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../i18n.dart';
import 'diag.dart';
import 'radio_rx.dart';
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
// Pure queue / auth-outage logic. Kept free of I/O so the semantics that
// protect fix data (cap, batching, remove-only-on-success) are unit-testable.
// ---------------------------------------------------------------------------

/// Durable GPS fix buffer: capped at [cap] (oldest dropped), uploaded in
/// [batchSize] chunks, and fixes are removed only after the server confirmed
/// the batch — a failed or unauthorized upload keeps every one of them.
class GpsQueue {
  static const int cap = 5000;
  static const int batchSize = 100;

  final List<Map<String, dynamic>> _items = [];

  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;

  /// Read-only view (persistence snapshot).
  List<Map<String, dynamic>> get items => List.unmodifiable(_items);

  /// Append a fix; drop the oldest once over [cap] so a long offline stretch
  /// can't grow unbounded.
  void add(Map<String, dynamic> fix) {
    _items.add(fix);
    if (_items.length > cap) _items.removeRange(0, _items.length - cap);
  }

  /// The oldest ≤[batchSize] fixes, in insertion order. Does NOT remove them —
  /// call [markUploaded] only after the server accepted the batch.
  List<Map<String, dynamic>> nextBatch() =>
      List<Map<String, dynamic>>.from(_items.take(batchSize));

  /// Drop the [count] oldest fixes after a confirmed upload.
  void markUploaded(int count) => _items.removeRange(0, count);

  /// Replace contents from a persisted snapshot.
  void restore(Iterable<Map<String, dynamic>> saved) {
    _items
      ..clear()
      ..addAll(saved);
  }
}

/// Tracks how long ingest uploads have been rejected with auth errors
/// (401/403 — stale token, and only the UI isolate may refresh it, see
/// [SessionStore]). After [warnAfter] of continuous auth failures the
/// persistent notification goes loud so the driver knows dispatch lost the
/// truck; a single successful upload resets it.
class AuthOutage {
  static const warnAfter = Duration(minutes: 5);

  DateTime? _since;

  /// True while the most recent upload attempt failed auth.
  bool get failing => _since != null;

  /// Note an auth failure; the clock starts at the FIRST failure of a streak.
  void recordAuthFailure(DateTime now) => _since ??= now;

  void recordSuccess() => _since = null;

  /// Should the notification be the loud warning right now?
  bool warnDue(DateTime now) =>
      _since != null && now.difference(_since!) >= warnAfter;
}

// ---------------------------------------------------------------------------
// Background isolate entry point + handler.
// ---------------------------------------------------------------------------

@pragma('vm:entry-point')
void trackingCallback() {
  FlutterForegroundTask.setTaskHandler(_TrackingHandler());
}

class _TrackingHandler extends TaskHandler {
  final GpsQueue _queue = GpsQueue();
  final AuthOutage _outage = AuthOutage();
  // The always-on radio receiver rides the same service: fleet audio keeps
  // playing when the app is closed, exactly like GPS keeps sampling.
  final RadioRx _radio = RadioRx();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _loadQueue();
    await _radio.tick(); // radio up within seconds of the service starting
    // Take one fix immediately so the map lights up without waiting a minute.
    await _sample();
  }

  // Called on the interval configured in ForegroundTaskOptions.
  @override
  void onRepeatEvent(DateTime timestamp) {
    _sample();
    _radio.tick(); // reconnect / re-auth / heartbeat
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _radio.dispose();
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
      await _persistQueue();
    } catch (e) {
      // Permission/location hiccup — try again next tick.
      Diag.log('gps: fix failed: $e');
    }
    // Flush + status still run when the fix failed, so queued points keep
    // draining and the notification/banner stay honest during GPS hiccups.
    await _flush();
    await _updateNotification();
    _reportToUi();
  }

  /// Surface state in the persistent notification: the normal "last fix" line,
  /// or a loud warning once uploads have been failing auth for a while — the
  /// only cure is the driver opening the app so the UI isolate hands over a
  /// fresh token.
  Future<void> _updateNotification() async {
    // Re-read the language each tick so a language switched in the UI reaches
    // this isolate — prefs snapshots go stale across isolates without reload.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await loadLocale();
    if (_outage.warnDue(DateTime.now())) {
      FlutterForegroundTask.updateService(
        notificationTitle: tr('notifTitleNotUploading'),
        notificationText:
            tr('notUploading').replaceFirst('{n}', '${_queue.length}'),
      );
      return;
    }
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    FlutterForegroundTask.updateService(
      notificationTitle: tr('notifTitleSharing'),
      notificationText: tr('notifLastFix')
          .replaceFirst('{t}', '$hh:$mm')
          .replaceFirst('{n}', '${_queue.length}'),
    );
  }

  /// Ship queue depth + auth health to the UI isolate; HomeShell shows a
  /// "uploads paused" banner and pushes a fresh token in response.
  void _reportToUi() {
    try {
      FlutterForegroundTask.sendDataToMain({
        'queued': _queue.length,
        'authStale': _outage.failing,
      });
    } catch (_) {
      // UI isolate gone — the notification still tells the story.
    }
  }

  Future<void> _flush() async {
    if (_queue.isEmpty) return;
    final token = await SessionStore.accessToken();
    if (token == null) return; // stale token: keep queuing, upload later.
    final batch = _queue.nextBatch();
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
        _queue.markUploaded(batch.length);
        await _persistQueue();
        if (_outage.failing) Diag.log('gps: uploads recovered');
        _outage.recordSuccess(); // uploads healthy again → normal notification.
      } else if (res.statusCode == 401 || res.statusCode == 403) {
        // Token stale: leave the queue, it flushes on next refresh. Note when
        // the outage started so the notification can go loud if it drags on.
        if (!_outage.failing) {
          Diag.log('gps: auth rejected (${res.statusCode}) — queuing');
        }
        _outage.recordAuthFailure(DateTime.now());
      } else {
        Diag.log('gps: ingest HTTP ${res.statusCode} — keeping batch');
      }
    } catch (e) {
      // Network down — keep the queue for the next tick.
      Diag.log('gps: upload failed: $e');
    }
  }

  Future<void> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(SessionStore.kGpsQueue);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List;
      _queue.restore(list.map((e) => Map<String, dynamic>.from(e as Map)));
    } catch (e) {
      Diag.log('gps: queue cache corrupt, dropped: $e');
    }
  }

  Future<void> _persistQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(SessionStore.kGpsQueue, jsonEncode(_queue.items));
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
        channelName: tr('notifChannelName'),
        channelDescription: tr('notifChannelDesc'),
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

  // The "Allow all the time" settings redirect nags at most once per app
  // session; resume-time re-checks stay silent.
  bool _askedForAlways = false;

  /// Location + notification permission. Returns the FINAL grant actually
  /// held — [LocationPermission.always] is the only state where always-on
  /// tracking fully works (screen-off sampling, restart after reboot), so
  /// callers should treat anything else as "not fully enabled".
  ///
  /// "Allow all the time" can NOT be obtained by calling requestPermission()
  /// again after while-in-use — Android silently ignores the back-to-back
  /// prompt. It's a Settings toggle, so we explain the step (when [context]
  /// is available) and redirect to app settings instead.
  Future<LocationPermission> ensurePermissions({BuildContext? context}) async {
    // Every prompt is best-effort: any of these throws PlatformException when
    // its dialog is dismissed or when two prompts race (emulator-verified),
    // and a denied permission must degrade to the banner, never an error
    // screen.
    try {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (e) {
      Diag.log('perm: battery opt: $e');
    }
    try {
      final notif = await FlutterForegroundTask.checkNotificationPermission();
      if (notif != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (e) {
      Diag.log('perm: notification: $e');
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      try {
        perm = await Geolocator.requestPermission();
      } catch (e) {
        Diag.log('perm: location request: $e');
        perm = await Geolocator.checkPermission();
      }
    }
    if (perm == LocationPermission.whileInUse && !_askedForAlways) {
      _askedForAlways = true;
      if (context != null && context.mounted) {
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(tr('oneMoreStep')),
            content: Text(tr('allowAllTimeBody')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(tr('notNow'))),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(tr('openSettings'))),
            ],
          ),
        );
        if (go == true) await Geolocator.openAppSettings();
      }
      // Settings opens as a separate screen, so this usually still reads
      // while-in-use; the resume re-check in HomeShell picks up the upgrade.
      perm = await Geolocator.checkPermission();
    }
    return perm;
  }

  Future<bool> isRunningServiceAsync() => FlutterForegroundTask.isRunningService;

  /// Start or stop always-on tracking. Returns true only when the grant fully
  /// backs "always on" (see [ensurePermissions]) so the UI's status chip is
  /// honest; with only while-in-use the service still starts (tracking works
  /// while the app session lives) but the fix-it banner stays up.
  Future<bool> setTracking(bool on, {BuildContext? context}) async {
    init();
    if (on) {
      final perm = await ensurePermissions(context: context);
      final usable = perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse;
      if (!usable) {
        Diag.log('tracking: location permission denied ($perm)');
        return false;
      }
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.restartService();
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 42,
          notificationTitle: tr('notifTitleSharing'),
          notificationText: tr('notifDispatchSees'),
          callback: trackingCallback,
        );
      }
      if (perm != LocationPermission.always) {
        Diag.log('tracking: running with while-in-use only');
      }
      return perm == LocationPermission.always;
    } else {
      await FlutterForegroundTask.stopService();
      return true;
    }
  }
}
