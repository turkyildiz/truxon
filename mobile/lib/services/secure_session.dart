import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';

/// The persisted Supabase session — which carries the long-lived REFRESH token,
/// not just the access token — lives in the platform keystore, never plaintext
/// SharedPreferences (M-3). On a shared cab tablet that removes the off-device
/// impersonation an attacker could get from root/ADB/physical extraction of the
/// prefs XML.
///
/// Shared by BOTH isolates: the UI isolate through [SecureLocalStorage] (wired
/// into Supabase.initialize) and the background service isolate through
/// AuthRefresher. flutter_secure_storage is a direct platform call with no
/// Dart-side cache, so each isolate always reads the latest write — exactly the
/// property [SessionStore]'s access-token store already relies on.
class SecureSession {
  static const _secure = FlutterSecureStorage();

  /// supabase_flutter's own persistence key (`sb-<ref>-auth-token`).
  static String get key =>
      'sb-${Uri.parse(AppConfig.supabaseUrl).host.split('.').first}-auth-token';

  /// Read the session blob, transparently migrating a pre-existing plaintext
  /// prefs copy into the keystore (then deleting the plaintext) so an in-place
  /// upgrade never signs the driver out.
  static Future<String?> read() async {
    final v = await _secure.read(key: key);
    if (v != null && v.isNotEmpty) return v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final legacy = prefs.getString(key);
      if (legacy != null && legacy.isNotEmpty) {
        await _secure.write(key: key, value: legacy);
        await prefs.remove(key); // no lingering plaintext refresh token
        return legacy;
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> has() async {
    final v = await read();
    return v != null && v.isNotEmpty;
  }

  static Future<void> write(String value) async {
    await _secure.write(key: key, value: value);
    // Belt-and-suspenders: never leave a stale plaintext copy behind.
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(key)) await prefs.remove(key);
    } catch (_) {}
  }

  static Future<void> remove() async {
    await _secure.delete(key: key);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {}
  }
}

/// [LocalStorage] adapter so supabase_flutter persists the session into the
/// keystore via [SecureSession] instead of the default plaintext prefs.
class SecureLocalStorage extends LocalStorage {
  const SecureLocalStorage();

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() => SecureSession.has();

  @override
  Future<String?> accessToken() => SecureSession.read();

  @override
  Future<void> removePersistedSession() => SecureSession.remove();

  @override
  Future<void> persistSession(String persistSessionString) =>
      SecureSession.write(persistSessionString);
}
