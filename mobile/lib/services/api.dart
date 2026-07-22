import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_refresher.dart';
import 'diag.dart';
import 'session_store.dart';
import 'tracking_service.dart';

final _sb = Supabase.instance.client;

class DriverLoad {
  DriverLoad(this.raw);
  final Map<String, dynamic> raw;

  int get id => raw['id'] as int;
  String get loadNumber => (raw['load_number'] ?? '') as String;
  String get status => (raw['status'] ?? '') as String;
  String get pickup => (raw['pickup_address'] ?? '') as String;
  String get delivery => (raw['delivery_address'] ?? '') as String;
  String? get customerName => raw['customer_name'] as String?;
  String? get truckUnit => raw['truck_unit'] as String?;
  bool get hasRate => raw.containsKey('rate'); // should always be false
}

class CompanionApi {
  Future<Map<String, dynamic>?> profile() async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return null;
    return await _sb.from('profiles').select().eq('id', uid).maybeSingle();
  }

  /// Severe-weather alerts pushed to THIS driver's truck (RLS: own alerts),
  /// not yet expired. Feeds the proactive co-pilot.
  Future<List<Map<String, dynamic>>> myWeatherAlerts() async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return const [];
    final data = await _sb
        .from('weather_alerts')
        .select('alert_id, event, severity, headline, area, expires_at')
        .eq('driver_user_id', uid)
        .or('expires_at.is.null,expires_at.gt.${DateTime.now().toUtc().toIso8601String()}')
        .order('created_at', ascending: false)
        .limit(10);
    return (data as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Trucker POIs (truck stops / rest areas / weigh stations) inside a
  /// map box — served from our own cache, never Overpass.
  Future<List<Map<String, dynamic>>> poisInBbox(
      double minLat, double minLon, double maxLat, double maxLon,
      {List<String>? kinds}) async {
    final data = await _sb.rpc('pois_in_bbox', params: {
      'p_min_lat': minLat,
      'p_min_lon': minLon,
      'p_max_lat': maxLat,
      'p_max_lon': maxLon,
      'p_kinds': ?kinds,
    });
    return ((data as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Live truck-parking availability (TPIMS state feeds) inside a map box.
  Future<List<Map<String, dynamic>>> parkingInBbox(
      double minLat, double minLon, double maxLat, double maxLon) async {
    final data = await _sb.rpc('parking_in_bbox', params: {
      'p_min_lat': minLat,
      'p_min_lon': minLon,
      'p_max_lat': maxLat,
      'p_max_lon': maxLon,
    });
    return ((data as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  // ── Office roles (admin/dispatcher/accountant) — mobile command views ──

  /// Live fleet positions (dispatcher/admin/accountant). One row per truck in
  /// motion: driver, unit, load, lat/lng, speed, last fix.
  Future<List<Map<String, dynamic>>> fleetPositions() async {
    final data = await _sb.rpc('fleet_positions_snapshot');
    return ((data as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Overdue-customer call queue (accountant/admin), priority-sorted, with
  /// phone for tap-to-dial.
  Future<List<Map<String, dynamic>>> collectionsQueue() async {
    final data = await _sb.rpc('collections_queue');
    return ((data as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// A/R KPI strip (accountant/admin): AR total, past-due, DSO, unbilled, MTD.
  Future<Map<String, dynamic>?> acctSummary() async {
    final data = await _sb.rpc('acct_summary');
    return data == null ? null : Map<String, dynamic>.from(data as Map);
  }

  /// Sentinel insight feed (admin/dispatcher/accountant): open money/cash/ops/
  /// compliance findings, most urgent first.
  Future<List<Map<String, dynamic>>> insightsFeed() async {
    final data = await _sb.rpc('trux_insights_feed', params: {'p_include_resolved': false});
    return ((data as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> acknowledgeInsight(int id) async {
    await _sb.rpc('acknowledge_insight', params: {'p_id': id});
  }

  /// Trucks a driver can inspect (DVIR).
  Future<List<Map<String, dynamic>>> listTrucks() async {
    final data = await _sb
        .from('trucks')
        .select('id, unit_number')
        .neq('status', 'retired')
        .order('unit_number');
    return (data as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Submit a pre/post-trip inspection; defects auto-file into maintenance.
  Future<bool> submitDvir({
    required int truckId,
    required String inspectionType,
    required Map<String, String> items,
    num? odometer,
    String defects = '',
    bool safe = true,
  }) async {
    final res = await _sb.rpc('submit_dvir', params: {
      'p_truck_id': truckId,
      'p_inspection_type': inspectionType,
      'p_items': items,
      'p_odometer': ?odometer,
      'p_defects': defects,
      'p_safe': safe,
    });
    return (res as Map)['defect_flagged'] == true;
  }

  /// Current NPS quarter label, e.g. 2026-Q3.
  static String npsQuarter([DateTime? now]) {
    final d = now ?? DateTime.now();
    return '${d.year}-Q${((d.month - 1) ~/ 3) + 1}';
  }

  /// Has this driver already answered the current quarter's survey?
  Future<bool> npsAnswered() async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return true; // signed out — never prompt
    final row = await _sb
        .from('driver_nps')
        .select('id')
        .eq('driver_user_id', uid)
        .eq('quarter', npsQuarter())
        .maybeSingle();
    return row != null;
  }

  Future<void> submitNps(int score, String comment) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return;
    await _sb.from('driver_nps').insert({
      'driver_user_id': uid,
      'quarter': npsQuarter(),
      'score': score,
      'comment': comment.trim(),
    });
  }

  /// The driver's own weekly card (loads, miles, est pay, on-time,
  /// detention). Null for unlinked/office logins.
  Future<Map<String, dynamic>?> myWeekScorecard() async {
    final data = await _sb.rpc('my_week_scorecard', params: {'p_week_offset': 0});
    if (data == null) return null;
    return Map<String, dynamic>.from(data as Map);
  }

  Future<List<DriverLoad>> myLoads() async {
    final data = await _sb.rpc('driver_my_loads');
    final list = (data as List?) ?? [];
    return list.map((e) => DriverLoad(Map<String, dynamic>.from(e as Map))).toList();
  }

  Future<DriverLoad> changeStatus(int loadId, String status) async {
    final data = await _sb.rpc('driver_change_load_status', params: {
      'p_load_id': loadId,
      'p_status': status,
    });
    return DriverLoad(Map<String, dynamic>.from(data as Map));
  }

  Future<void> setDuty(bool onDuty) async {
    await _sb.rpc('driver_set_duty', params: {'p_on_duty': onDuty});
  }

  // NOTE: no ingest_vehicle_positions wrapper here on purpose — the tracking
  // isolate posts to that RPC over raw REST (Supabase.instance never exists
  // in that isolate), and one ingest path is enough.

  Future<List<Map<String, dynamic>>> listDocuments(int loadId) async {
    final data = await _sb.rpc('driver_list_documents', params: {'p_load_id': loadId});
    final list = (data as List?) ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<String?> signedDocUrl(String storagePath) async {
    return await _sb.storage.from('documents').createSignedUrl(storagePath, 180);
  }

  /// Feature 3 — upload a delivery-receipt / POD photo for one of the driver's
  /// own loads. Uploads to the `documents` bucket under `load/<id>/…` (the path
  /// the driver storage policy + driver_add_document RPC both require), then
  /// registers the metadata row so it shows up on the web load and pings
  /// dispatch via the activity log.
  Future<Map<String, dynamic>> uploadReceipt(
    int loadId,
    Uint8List bytes, {
    String docType = 'pod',
    String? filename,
    String contentType = 'image/jpeg',
    String? ocrText,
  }) async {
    final safeName = (filename == null || filename.isEmpty) ? 'photo.jpg' : filename;
    final unique = DateTime.now().microsecondsSinceEpoch;
    final path = 'load/$loadId/${unique}_$safeName';
    await _sb.storage.from('documents').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: false),
        );
    final data = await _sb.rpc('driver_add_document', params: {
      'p_load_id': loadId,
      'p_storage_path': path,
      'p_filename': safeName,
      'p_content_type': contentType,
      'p_size_bytes': bytes.length,
      'p_doc_type': docType,
      if (ocrText != null && ocrText.isNotEmpty) 'p_ocr_text': ocrText,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  /// Feature 2 — send a message to the Trux agent (edge fn `trux-agent`,
  /// propose mode). Returns the raw response (reply text + optional confirm
  /// card). Pass [sessionId] to keep a conversation, or a confirm/reject token.
  Future<Map<String, dynamic>> truxSend({
    String? sessionId,
    String? message,
    String? confirmToken,
    String? rejectToken,
    bool radio = false,
  }) async {
    final res = await _sb.functions.invoke('trux-agent', body: {
      'session_id': ?sessionId,
      'message': ?message,
      'confirm_token': ?confirmToken,
      'reject_token': ?rejectToken,
      if (radio) 'radio': true,
    });
    final data = res.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return {'reply': data?.toString() ?? ''};
  }

  /// Register FCM/APNs token with notify edge function.
  Future<void> registerPushToken(String token, String platform) async {
    await _sb.functions.invoke('notify', body: {
      'action': 'register',
      'token': token,
      'platform': platform,
    });
  }

  Future<void> unregisterPushToken(String token) async {
    await _sb.functions.invoke('notify', body: {
      'action': 'unregister',
      'token': token,
    });
  }

  /// Keep the session fresh THROUGH THE SINGLE SHARED PATH ([AuthRefresher] —
  /// never auth.refreshSession() directly, that's a second refresh-token
  /// spender and races the background service into a logout), then make the
  /// live client adopt whatever is now persisted. Called on resume, on the
  /// keep-fresh timer, and whenever the tracker reports auth failures.
  Future<void> pushFreshTokenToTracker() async {
    final fresh = await AuthRefresher.ensureFresh();
    if (fresh == null) return; // signed out (or unrecoverable) — nothing to push
    if (fresh != _sb.auth.currentSession?.accessToken) {
      // The refresher (possibly in the service isolate) rotated the session;
      // adopt the persisted copy so this client's requests + realtime use it.
      // Only adopt a LIVE session — recovering an expired one would trigger
      // gotrue's own internal refresh outside the lock.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final raw = prefs.getString(AuthRefresher.persistKey);
        if (raw != null) {
          final sess = Map<String, dynamic>.from(jsonDecode(raw) as Map);
          final exp = (sess['expires_at'] as num?)?.toInt() ?? 0;
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          if (exp - now > 60) await _sb.auth.recoverSession(raw);
        }
      } catch (e) {
        Diag.log('auth: adopt failed: $e');
      }
    }
    await SessionStore.saveAccessToken(
        _sb.auth.currentSession?.accessToken ?? fresh);
  }

  /// Sign out MUST also kill the GPS foreground service and wipe the offline
  /// queues — a returned/shared device must not keep tracking or hold the
  /// previous driver's queued points (security report P0).
  Future<void> signOut() async {
    try {
      await TruxTrackingService.instance.setTracking(false);
    } catch (_) {/* never block sign-out on the tracker */}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(SessionStore.kGpsQueue);
      await prefs.remove('status_outbox');
    } catch (_) {}
    await SessionStore.saveAccessToken(null);
    await _sb.auth.signOut();
  }
}

/// Offline outbox for status changes + GPS points (SharedPreferences-backed simple JSON).
class OfflineOutbox {
  static List<Map<String, dynamic>> decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      // Corrupt SharedPreferences must not brick the loads UI — drop the
      // queue and start clean, same as the GPS queue path does.
      Diag.log('outbox: corrupt cache dropped: $e');
      return [];
    }
  }

  static String encode(List<Map<String, dynamic>> items) => jsonEncode(items);

  /// Replay [items] oldest-first through [send]. Returns the ones that still
  /// failed, preserving their original order for the next attempt — one
  /// failure doesn't stop later items from being tried.
  static Future<List<Map<String, dynamic>>> replay(
    List<Map<String, dynamic>> items,
    Future<void> Function(Map<String, dynamic> item) send,
  ) async {
    final remaining = <Map<String, dynamic>>[];
    for (final item in items) {
      try {
        await send(item);
      } catch (_) {
        remaining.add(item);
      }
    }
    return remaining;
  }
}
