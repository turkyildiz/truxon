import 'package:flutter_test/flutter_test.dart';

import 'package:truxon_companion/i18n.dart';

/// tr() fallback chain (locale → English → key itself) plus a parity check so
/// a key added to English can't silently go missing in the other 9 locales.
void main() {
  tearDown(() => appLocale.value = 'en');

  test('known key translates in the active locale', () {
    appLocale.value = 'es';
    expect(tr('loads'), 'Cargas');
  });

  test('unknown key falls back to the key itself', () {
    appLocale.value = 'en';
    expect(tr('definitely_not_a_key'), 'definitely_not_a_key');
  });

  test('unknown locale falls back to English', () {
    appLocale.value = 'xx';
    expect(tr('loads'), 'Loads');
  });

  test('key missing from a locale falls back to English before the key', () {
    // All locales are currently complete (verified below), so simulate the
    // gap with an unknown locale + known key: en value, not the raw key.
    appLocale.value = 'xx';
    expect(tr('uploadsPaused'), 'Location uploads paused — reconnecting…');
  });

  test('every locale in kLangs has a full set of keys, incl. the {n} placeholder', () {
    final enKeys = translations['en']!.keys.toSet();
    for (final lang in kLangs) {
      final table = translations[lang.code];
      expect(table, isNotNull, reason: 'no table for ${lang.code}');
      expect(table!.keys.toSet(), enKeys, reason: 'key drift in ${lang.code}');
      // The tracker notification substitutes the queued count into {n}.
      expect(table['notUploading'], contains('{n}'),
          reason: 'notUploading in ${lang.code} lost its {n} placeholder');
    }
  });
}
