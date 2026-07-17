import 'dart:convert';
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  Future<Map<String, dynamic>> ingestPositions(List<Map<String, dynamic>> points) async {
    final data = await _sb.rpc('ingest_vehicle_positions', params: {
      'p_points': points,
    });
    return Map<String, dynamic>.from(data as Map);
  }

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
  }) async {
    final res = await _sb.functions.invoke('trux-agent', body: {
      if (sessionId != null) 'session_id': sessionId,
      if (message != null) 'message': message,
      if (confirmToken != null) 'confirm_token': confirmToken,
      if (rejectToken != null) 'reject_token': rejectToken,
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

  Future<void> signOut() => _sb.auth.signOut();
}

/// Offline outbox for status changes + GPS points (SharedPreferences-backed simple JSON).
class OfflineOutbox {
  static List<Map<String, dynamic>> decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static String encode(List<Map<String, dynamic>> items) => jsonEncode(items);
}
