/// Runtime config. Prefer --dart-define so secrets never land in source.
class AppConfig {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: '',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  /// GPS sample interval while tracking is allowed.
  static const gpsInterval = Duration(seconds: 60);

  // ---- Trux voice (Feature 2) ----
  /// Preferred TTS locale — a British voice, Jarvis-style. Overridable at build
  /// time with --dart-define=TRUX_VOICE_LOCALE=en-GB.
  static const truxVoiceLocale = String.fromEnvironment(
    'TRUX_VOICE_LOCALE',
    defaultValue: 'en-GB',
  );

  // ---- Mumble PTT (Feature 5) ----
  /// NAS tailnet address of the Murmur server (reachable over the Tailscale VPN).
  static const mumbleHost = String.fromEnvironment(
    'MUMBLE_HOST',
    defaultValue: '100.89.140.98',
  );
  static const mumblePort = int.fromEnvironment('MUMBLE_PORT', defaultValue: 64738);

  // ---- Alarm channel (Feature 6) ----
  static const alarmChannelId = 'dispatch_alarm';
  static const alarmChannelName = 'Dispatch alarms';

  // ---- Self-update (OTA) ----
  /// URL of the hosted latest.json describing the newest APK. When empty the
  /// updater is a no-op. Override at build time with
  /// --dart-define=UPDATE_URL=https://…/latest.json
  static const updateManifestUrl = String.fromEnvironment(
    'UPDATE_URL',
    // GitHub's /releases/latest/download/ always resolves to the newest
    // release's asset — no branch to push, no token anywhere in the app.
    defaultValue: 'https://github.com/turkyildiz/truxon-releases/releases/latest/download/latest.json',
  );
}
