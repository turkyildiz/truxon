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
class SessionStore {
  static const kAccessToken = 'sb_access_token';
  static const kGpsQueue = 'gps_queue';
  static const kTrackingOn = 'tracking_on';

  static Future<void> saveAccessToken(String? token) async {
    final prefs = await SharedPreferences.getInstance();
    if (token == null || token.isEmpty) {
      await prefs.remove(kAccessToken);
    } else {
      await prefs.setString(kAccessToken, token);
    }
  }

  static Future<String?> accessToken() async {
    final prefs = await SharedPreferences.getInstance();
    // The background isolate caches a snapshot; reload so it sees the token the
    // UI isolate refreshed after this isolate started.
    await prefs.reload();
    return prefs.getString(kAccessToken);
  }

  static Future<void> setTrackingFlag(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kTrackingOn, on);
  }

  static Future<bool> trackingFlag() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kTrackingOn) ?? false;
  }
}
