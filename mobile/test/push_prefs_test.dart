import 'package:flutter_test/flutter_test.dart';
import 'package:truxon_companion/services/push_prefs.dart';

void main() {
  group('PushPrefs.allowedFor', () {
    test('critical types always ring, even when everything is off', () {
      final allOff = {for (final k in PushPrefs.optional.keys) k: false};
      expect(PushPrefs.allowedFor('assignment', allOff), true);
      expect(PushPrefs.allowedFor('breakdown', allOff), true);
    });

    test('optional types honor their toggle', () {
      expect(PushPrefs.allowedFor('weather', {'weather': false}), false);
      expect(PushPrefs.allowedFor('weather', {'weather': true}), true);
      expect(PushPrefs.allowedFor('paperwork', {'paperwork': false}), false);
    });

    test('unknown or missing types fall under other', () {
      expect(PushPrefs.allowedFor('mystery', {'other': false}), false);
      expect(PushPrefs.allowedFor(null, {'other': false}), false);
      expect(PushPrefs.allowedFor('mystery', {}), true);
    });
  });
}
