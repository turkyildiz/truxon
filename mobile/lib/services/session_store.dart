import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bridge between the UI isolate (which owns the Supabase session) and the
/// background tracking isolate (which only does plain REST calls). The UI
/// writes the current access token here on login and on every token refresh;
/// the background isolate reads it to authenticate `ingest_vehicle_positions`.
///
/// We deliberately do NOT refresh tokens in the background isolate: Supabase
/// rotates refresh tokens, and a second refresher would invalidate the UI's
/// session and log the driver out. Instead the tracker keeps sampling and
/// queues points locally whenever the token is stale; they flush the moment a
/// fresh token appears (app foreground / token refresh). No fix data is lost.
///
/// The token itself lives in flutter_secure_storage (Android Keystore-backed),
/// NOT SharedPreferences — a bearer token shouldn't sit in plaintext XML. This
/// works from the tracking isolate too: the foreground service spawns its
/// FlutterEngine with automatic plugin registration (the same reason
/// SharedPreferences works there), and secure storage has no Dart-side cache —
/// every read is a platform call into the shared per-process store — so the
/// isolate always sees the latest token without any reload() dance.
class SessionStore {
  static const kAccessToken = 'sb_access_token';
  static const kGpsQueue = 'gps_queue';

  static const _secure = FlutterSecureStorage();

  static Future<void> saveAccessToken(String? token) async {
    if (token == null || token.isEmpty) {
      await _secure.delete(key: kAccessToken);
    } else {
      await _secure.write(key: kAccessToken, value: token);
    }
    // Builds before the secure-storage move kept the token in plain
    // SharedPreferences — make sure no plaintext copy lingers after upgrade.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kAccessToken);
  }

  static Future<String?> accessToken() => _secure.read(key: kAccessToken);
}
