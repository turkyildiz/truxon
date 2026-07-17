import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import 'api.dart';

/// Samples location every 60s while [trackingAllowed], queues offline, flushes to ingest RPC.
class GpsTracker {
  GpsTracker(this.api);

  final CompanionApi api;
  Timer? _timer;
  bool trackingAllowed = false;
  final List<Map<String, dynamic>> _queue = [];

  Future<void> start() async {
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
    _timer?.cancel();
    _timer = Timer.periodic(AppConfig.gpsInterval, (_) => _tick());
    await _tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (!trackingAllowed) return;
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
      await flush();
    } catch (_) {
      // Permission or location unavailable — try again next tick.
    }
  }

  Future<void> flush() async {
    if (_queue.isEmpty) return;
    final batch = List<Map<String, dynamic>>.from(_queue.take(60));
    try {
      await api.ingestPositions(batch);
      _queue.removeRange(0, batch.length);
      await _persistQueue();
    } catch (_) {
      // Keep queue for next attempt.
    }
  }

  Future<void> _persistQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gps_queue', OfflineOutbox.encode(_queue));
  }

  Future<void> loadPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    final items = OfflineOutbox.decode(prefs.getString('gps_queue'));
    _queue
      ..clear()
      ..addAll(items);
  }
}
