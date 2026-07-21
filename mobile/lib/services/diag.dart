import 'package:shared_preferences/shared_preferences.dart';

/// Tiny persistent field log. The spots that used to swallow errors with a
/// bare `catch (_) {}` now drop one line here, so a tracking problem on a
/// driver's tablet can be diagnosed from the About tab instead of over the
/// phone. Hand-rolled on purpose: the last [maxLines] lines as a
/// SharedPreferences string list, newest last, written from both the UI and
/// the tracking isolates (last-writer-wins — diagnostics, not an audit trail).
class Diag {
  static const kLog = 'diag_log';
  static const maxLines = 200;
  static const _stampLen = 19; // 'YYYY-MM-DDTHH:MM:SS'

  /// Pure ring semantics, unit-tested: append '[stamp] message', drop the
  /// oldest lines past [maxLines], and skip a message identical to the
  /// previous line's — a flapping network logging every 60s would otherwise
  /// evict everything useful. Returns [lines] unchanged (same identity) when
  /// the append was skipped.
  static List<String> appendLine(
      List<String> lines, String stamp, String message) {
    final last = lines.isNotEmpty ? lines.last : '';
    if (last.length > _stampLen + 1 &&
        last.substring(_stampLen + 1) == message) {
      return lines; // consecutive duplicate — keep the first occurrence
    }
    final out = [...lines, '$stamp $message'];
    return out.length <= maxLines ? out : out.sublist(out.length - maxLines);
  }

  /// Append one timestamped line. Best-effort by design.
  static Future<void> log(String message) async {
    // Also surface in logcat so emulator/adb debugging sees the field log
    // live (release builds included).
    // ignore: avoid_print
    print('[diag] $message');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // pick up lines the other isolate wrote
      final lines = prefs.getStringList(kLog) ?? const [];
      final stamp = DateTime.now().toIso8601String().substring(0, _stampLen);
      final out = appendLine(lines, stamp, message);
      if (!identical(out, lines)) await prefs.setStringList(kLog, out);
    } catch (_) {/* diagnostics must never take the app down */}
  }

  /// All stored lines, oldest first (About tab shows them newest-first).
  static Future<List<String>> read() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getStringList(kLog) ?? const [];
  }
}
