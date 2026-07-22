import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'diag.dart';
import 'session_store.dart';

/// THE single token refresher — the only code in the app allowed to spend a
/// refresh token.
///
/// Supabase rotates refresh tokens: each one is single-use, and using a stale
/// one revokes the whole session (instant driver logout — the bug class the
/// old "only the UI refreshes" rule existed to prevent). That rule capped the
/// background radio/GPS at ~1h after the app closed. This replaces it:
/// supabase_flutter's built-in auto-refresh is DISABLED (main.dart), and both
/// isolates call [ensureFresh] instead. A SharedPreferences claim-and-settle
/// lock (same file, same process, both isolates) guarantees at most one
/// refresh happens per expiry no matter who noticed first.
///
/// The refreshed session is written back to supabase_flutter's own
/// persistence key, so a cold app start recovers it natively, and the live UI
/// adopts it via `auth.recoverSession(raw)` (HomeShell's keep-fresh timer).
class AuthRefresher {
  static const kLock = 'auth_refresh_lock';

  /// Refresh when less than this much lifetime remains. Must comfortably
  /// exceed the callers' tick intervals (UI 3min, service ~1min) so a token
  /// never quietly runs out between checks.
  static const refreshSkew = Duration(minutes: 10);

  /// Consider a leftover lock crashed/stale after this long.
  static const lockTtl = Duration(seconds: 30);

  /// supabase_flutter's own persistence key (`sb-<ref>-auth-token`).
  static String get persistKey =>
      'sb-${Uri.parse(AppConfig.supabaseUrl).host.split('.').first}-auth-token';

  // ---- pure helpers (unit-tested) ----

  /// Does the persisted session need a refresh at [nowSecs]?
  static bool needsRefresh(Map<String, dynamic> session, int nowSecs) {
    final exp = (session['expires_at'] as num?)?.toInt() ?? 0;
    return exp - nowSecs <= refreshSkew.inSeconds;
  }

  /// Is [lockVal] ("nonce:millis") still held by a live refresher at [nowMs]?
  static bool lockHeld(String? lockVal, int nowMs) {
    if (lockVal == null || lockVal.isEmpty) return false;
    final i = lockVal.lastIndexOf(':');
    final ts = i < 0 ? null : int.tryParse(lockVal.substring(i + 1));
    if (ts == null) return false;
    return nowMs - ts < lockTtl.inMilliseconds;
  }

  /// Merge a refresh-endpoint response into the persisted session JSON,
  /// keeping fields the endpoint doesn't return.
  static Map<String, dynamic> mergeSession(
      Map<String, dynamic> old, Map<String, dynamic> resp, int nowSecs) {
    return {
      ...old,
      'access_token': resp['access_token'],
      'refresh_token': resp['refresh_token'],
      if (resp['token_type'] != null) 'token_type': resp['token_type'],
      'expires_in': resp['expires_in'],
      'expires_at': (resp['expires_at'] as num?)?.toInt() ??
          nowSecs + ((resp['expires_in'] as num?)?.toInt() ?? 3600),
      if (resp['user'] != null) 'user': resp['user'],
    };
  }

  // ---- the refresher ----

  static final _rand = Random();
  static Future<void>? _inflight;

  /// Make sure the persisted session is fresh enough, refreshing it here if
  /// nobody else already is. Returns the current access token, or null when
  /// signed out. Never throws; on any failure the old token is returned and
  /// the next tick retries.
  static Future<String?> ensureFresh() async {
    // In-isolate reentrancy guard (cross-isolate is the prefs lock's job).
    while (_inflight != null) {
      await _inflight;
    }
    final done = Completer<void>();
    _inflight = done.future;
    try {
      return await _ensureFresh();
    } finally {
      _inflight = null;
      done.complete();
    }
  }

  static Future<String?> _ensureFresh() async {
    String? lastAccess; // survive into the catch — a network error is not a sign-out
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(persistKey);
      if (raw == null || raw.isEmpty) return null; // signed out
      Map<String, dynamic> sess;
      try {
        sess = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {
        return null;
      }
      final access = sess['access_token'] as String?;
      final refresh = sess['refresh_token'] as String?;
      lastAccess = access;
      if (access == null || refresh == null) return access;
      // Keep the tracker's copy in sync even when no refresh is needed —
      // covers the cold service start before any UI handoff.
      await SessionStore.saveAccessToken(access);

      final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (!needsRefresh(sess, nowSecs)) return access;

      // Claim-and-settle lock: write a nonce, wait, and only the writer whose
      // nonce survived does the network call. Both isolates share the same
      // prefs file in the same process, so last-writer-wins is deterministic.
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (lockHeld(prefs.getString(kLock), nowMs)) return access;
      final nonce = List.generate(4, (_) => _rand.nextInt(1 << 30)).join('-');
      await prefs.setString(kLock, '$nonce:$nowMs');
      await Future.delayed(const Duration(milliseconds: 250));
      await prefs.reload();
      if (!(prefs.getString(kLock) ?? '').startsWith('$nonce:')) {
        return access; // lost the claim — the winner is refreshing
      }

      try {
        final res = await http
            .post(
              Uri.parse(
                  '${AppConfig.supabaseUrl}/auth/v1/token?grant_type=refresh_token'),
              headers: {
                'apikey': AppConfig.supabaseAnonKey,
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'refresh_token': refresh}),
            )
            .timeout(const Duration(seconds: 20));
        if (res.statusCode == 200) {
          final body = Map<String, dynamic>.from(jsonDecode(res.body) as Map);
          final merged = mergeSession(sess, body, nowSecs);
          await prefs.setString(persistKey, jsonEncode(merged));
          final newAccess = merged['access_token'] as String;
          await SessionStore.saveAccessToken(newAccess);
          Diag.log('auth: refreshed (single-path)');
          return newAccess;
        }
        // 400/401/403: token revoked or already rotated server-side. Leave
        // the stored session alone — clearing it here would sign the driver
        // out from a background isolate. The UI surfaces re-login.
        Diag.log('auth: refresh rejected HTTP ${res.statusCode}');
        return access;
      } finally {
        await prefs.remove(kLock);
      }
    } catch (e) {
      Diag.log('auth: refresh failed: $e');
      return lastAccess;
    }
  }
}
