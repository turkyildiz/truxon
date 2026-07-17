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
}
