import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import 'api.dart';
import 'diag.dart';
import 'forest_radio.dart';

/// A single thing the co-pilot should say, with a dedup key so it's said once.
class CopilotCue {
  const CopilotCue(this.key, this.text);
  final String key;
  final String text;
}

/// Proactive Forest — the co-pilot that speaks up unprompted, TO the driver
/// (local voice, not fleet radio). It reuses everything already built:
/// weather alerts pushed to this truck, and the active load's stop coordinates
/// the map already knows. Two cues today, both from data we already have:
///   * a severe-weather warning reached your truck → say it
///   * you're rolling into your stop → log the arrival + flag detention
///
/// The DECISION is a pure function ([decide]) so it's unit-tested; the runtime
/// just polls position + context and speaks whatever is new. Best-effort
/// everywhere — a co-pilot that crashes the app is worse than a quiet one.
class ForestCopilot {
  ForestCopilot(this._api, this._radio);
  final CompanionApi _api;
  final ForestRadio _radio;

  Timer? _timer;
  final Set<String> _said = {};
  bool _running = false;
  String? _dvirDay;
  bool _dvirDone = false;

  /// Arrival is announced within this radius of the active stop.
  static const arriveKm = 0.8;

  /// Great-circle distance in km.
  static double distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// Pure decision: given where the driver is, their active load, the weather
  /// alerts on their truck, and what's already been said, return the NEW cues.
  /// No I/O — this is the tested core.
  static List<CopilotCue> decide({
    double? lat,
    double? lon,
    Map<String, dynamic>? load,
    required List<Map<String, dynamic>> alerts,
    required Set<String> said,
    double? speedMps,
    bool? dvirDoneToday,
    String? today,
  }) {
    final cues = <CopilotCue>[];

    // 0) Rolling without a pre-trip DVIR. Only when we positively know one is
    //    missing (null = unknown → stay quiet) and the truck is actually
    //    moving (> ~11 mph, not a lot repositioning creep). Once per day.
    if (dvirDoneToday == false && today != null && (speedMps ?? 0) > 5) {
      final key = 'dvir:$today';
      if (!said.contains(key)) {
        cues.add(CopilotCue(key,
            "Before you get too far — I don't see a pre-trip inspection from you today. Next time you're stopped, pull up the DVIR checklist and knock it out."));
      }
    }

    // 1) Severe weather that reached this truck.
    for (final a in alerts) {
      final id = a['alert_id']?.toString();
      if (id == null) continue;
      final key = 'wx:$id';
      if (said.contains(key)) continue;
      final event = (a['event']?.toString() ?? 'severe weather').trim();
      final headline = (a['headline']?.toString() ?? '').trim();
      final text = headline.isNotEmpty
          ? 'Heads up — $event in your area. $headline'
          : 'Heads up — $event warning in your area. Stay sharp.';
      cues.add(CopilotCue(key, text));
    }

    // 2) Arrival at the active stop (delivery when rolling, else pickup).
    if (lat != null && lon != null && load != null) {
      final status = load['status']?.toString();
      final active = status == 'assigned' || status == 'in_transit';
      if (active) {
        final toDelivery = status == 'in_transit';
        final tLat = (load[toDelivery ? 'delivery_lat' : 'pickup_lat'] as num?)?.toDouble();
        final tLon = (load[toDelivery ? 'delivery_lon' : 'pickup_lon'] as num?)?.toDouble();
        if (tLat != null && tLon != null) {
          final km = distanceKm(lat, lon, tLat, tLon);
          final stage = toDelivery ? 'delivery' : 'pickup';
          final key = 'arrive:${load['id']}:$stage';
          if (km <= arriveKm && !said.contains(key)) {
            final word = toDelivery ? 'delivery' : 'pickup';
            cues.add(CopilotCue(key,
                "You're arriving at your $word. I've logged your arrival — if they keep you waiting, the detention clock is running."));
          }
        }
      }
    }
    return cues;
  }

  /// Start polling (driver only). Idempotent. Runs a light check every
  /// [interval]; the heavy foreground-service GPS is untouched — this just
  /// reads the last position cheaply.
  void start({Duration interval = const Duration(seconds: 90)}) {
    if (_running) return;
    _running = true;
    _tick(); // once at startup
    _timer = Timer.periodic(interval, (_) => _tick());
    Diag.log('copilot: on');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  Future<void> _tick() async {
    try {
      Position? pos;
      try {
        pos = await Geolocator.getLastKnownPosition();
      } catch (_) {}
      final loads = await _api.myLoads();
      final active = loads
          .map((l) => l.raw)
          .cast<Map<String, dynamic>?>()
          .firstWhere(
            (r) => r?['status'] == 'assigned' || r?['status'] == 'in_transit',
            orElse: () => null,
          );
      List<Map<String, dynamic>> alerts = const [];
      try {
        alerts = await _api.myWeatherAlerts();
      } catch (_) {}

      // DVIR check is cheap (RLS-scoped select limit 1) but only until it
      // turns true — once today's pre-trip is in, stop asking the server.
      final day = DateTime.now().toIso8601String().substring(0, 10);
      if (_dvirDay != day) {
        _dvirDay = day;
        _dvirDone = false;
      }
      bool? dvirDone;
      if (!_dvirDone) {
        try {
          _dvirDone = await _api.dvirDoneToday();
          dvirDone = _dvirDone;
        } catch (_) {} // unknown → decide() stays quiet
      } else {
        dvirDone = true;
      }

      final cues = decide(
        lat: pos?.latitude,
        lon: pos?.longitude,
        load: active,
        alerts: alerts,
        said: _said,
        speedMps: pos?.speed,
        dvirDoneToday: dvirDone,
        today: day,
      );
      for (final c in cues) {
        _said.add(c.key);
        await _radio.speak(c.text);
        Diag.log('copilot: said ${c.key}');
      }
    } catch (e) {
      Diag.log('copilot: tick failed: $e');
    }
  }
}
