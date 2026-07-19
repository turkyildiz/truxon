import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:truxon_companion/services/diag.dart';

/// Field-log ring buffer: bounded, ordered, and quiet about repeats — so a
/// flapping network can't evict the one line that explains the real problem.
void main() {
  const stamp = '2026-07-19T12:00:00';

  group('Diag.appendLine (pure ring semantics)', () {
    test('appends a stamped line', () {
      final out = Diag.appendLine(['$stamp boot'], stamp, 'gps: fix failed');
      expect(out, ['$stamp boot', '$stamp gps: fix failed']);
    });

    test('keeps only the newest maxLines lines', () {
      var lines = <String>[];
      for (var i = 0; i < Diag.maxLines + 10; i++) {
        lines = Diag.appendLine(lines, stamp, 'msg $i');
      }
      expect(lines.length, Diag.maxLines);
      expect(lines.first, '$stamp msg 10'); // oldest 10 evicted
      expect(lines.last, '$stamp msg ${Diag.maxLines + 9}');
    });

    test('skips a consecutive duplicate message (identical list back)', () {
      final once = Diag.appendLine([], stamp, 'gps: upload failed: offline');
      final twice =
          Diag.appendLine(once, '2026-07-19T12:01:00', 'gps: upload failed: offline');
      expect(identical(twice, once), isTrue);
    });

    test('does not dedupe when another message came between', () {
      var lines = Diag.appendLine([], stamp, 'a');
      lines = Diag.appendLine(lines, stamp, 'b');
      lines = Diag.appendLine(lines, stamp, 'a');
      expect(lines.length, 3);
    });
  });

  group('Diag.log / Diag.read (mocked prefs)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('log persists and read returns oldest-first', () async {
      SharedPreferences.setMockInitialValues({});
      await Diag.log('first');
      await Diag.log('second');
      final lines = await Diag.read();
      expect(lines.length, 2);
      expect(lines[0], endsWith(' first'));
      expect(lines[1], endsWith(' second'));
    });
  });
}
