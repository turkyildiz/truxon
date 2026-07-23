import 'package:shared_preferences/shared_preferences.dart';

/// R9 #146 — notification preferences. Drivers can quiet the optional
/// categories (weather, paperwork nudges); safety-critical types (a new
/// assignment, a breakdown) always ring — a preference must never be able to
/// silence dispatch reaching a moving truck.
class PushPrefs {
  static const _prefix = 'push_pref_';

  /// Types that can never be muted.
  static const critical = {'assignment', 'breakdown'};

  /// The user-facing toggles: type → label.
  static const optional = {
    'weather': 'Severe weather alerts',
    'paperwork': 'Paperwork reminders',
    'other': 'Everything else',
  };

  /// Pure decision, unit-tested: is this message type allowed given the
  /// stored toggle values? Unknown/absent types fall under 'other'.
  static bool allowedFor(String? type, Map<String, bool> toggles) {
    final t = (type == null || type.isEmpty) ? 'other' : type;
    if (critical.contains(t)) return true;
    final key = optional.containsKey(t) ? t : 'other';
    return toggles[key] ?? true;
  }

  static Future<bool> allowed(String? type) async {
    if (type != null && critical.contains(type)) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final toggles = {
        for (final k in optional.keys) k: prefs.getBool('$_prefix$k') ?? true,
      };
      return allowedFor(type, toggles);
    } catch (_) {
      return true; // prefs unreadable — never drop a message over it
    }
  }

  static Future<bool> get(String type) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('$_prefix$type') ?? true;
  }

  static Future<void> set(String type, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_prefix$type', value);
  }
}
