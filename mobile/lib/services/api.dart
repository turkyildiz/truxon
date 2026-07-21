import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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
      if (kinds != null) 'p_kinds': kinds,
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
      if (odometer != null) 'p_odometer': odometer,
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
      if (sessionId != null) 'session_id': sessionId,
      if (message != null) 'message': message,
      if (confirmToken != null) 'confirm_token': confirmToken,
      if (rejectToken != null) 'reject_token': rejectToken,
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

  /// Hand the current access token to the background GPS isolate, refreshing
  /// it first if it went stale while the app was backgrounded. UI isolate
  /// only — the tracker deliberately never refreshes tokens itself (see
  /// [SessionStore] for why). Called on app resume and whenever the tracker
  /// reports auth failures, so queued fixes flush on the next tick.
  Future<void> pushFreshTokenToTracker() async {
    var session = _sb.auth.currentSession;
    if (session == null) return;
    if (session.isExpired) {
      try {
        await _sb.auth.refreshSession();
      } catch (_) {/* offline — the next resume/report tries again */}
      session = _sb.auth.currentSession;
    }
    await SessionStore.saveAccessToken(session?.accessToken);
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
