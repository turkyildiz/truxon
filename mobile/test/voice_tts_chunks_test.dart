import 'package:flutter_test/flutter_test.dart';
import 'package:truxon_companion/services/trux_voice.dart';

// Forest was cutting off long spoken replies because on-device TTS (Android's
// engine) rejects/truncates strings past ~4000 chars. ttsChunks splits a reply
// into sentence-sized pieces that never hit the cap — this pins that it never
// loses content and never emits an over-cap chunk.
void main() {
  const cap = 450;

  test('short text is one chunk, unchanged', () {
    expect(TruxVoiceController.ttsChunks('Load 1197 is on route.'),
        ['Load 1197 is on route.']);
  });

  test('empty / whitespace → no chunks', () {
    expect(TruxVoiceController.ttsChunks(''), isEmpty);
    expect(TruxVoiceController.ttsChunks('   '), isEmpty);
  });

  test('a long multi-sentence reply: every chunk <= cap, nothing dropped', () {
    final sentence = 'Truck 12 delivered the Chicago load and is now empty. ';
    final long = (sentence * 40).trim(); // ~2000 chars
    final chunks = TruxVoiceController.ttsChunks(long);
    expect(chunks.length, greaterThan(1));
    for (final c in chunks) {
      expect(c.length, lessThanOrEqualTo(cap), reason: 'chunk over cap: ${c.length}');
    }
    // content preserved (word-for-word, order kept)
    expect(chunks.join(' ').replaceAll(RegExp(r'\s+'), ' '),
        long.replaceAll(RegExp(r'\s+'), ' '));
  });

  test('a single sentence longer than the cap is word-split, still <= cap', () {
    final oneLongSentence = List.filled(120, 'word').join(' '); // ~600 chars, no punctuation
    final chunks = TruxVoiceController.ttsChunks(oneLongSentence);
    expect(chunks.length, greaterThan(1));
    for (final c in chunks) {
      expect(c.length, lessThanOrEqualTo(cap));
    }
    expect(chunks.join(' '), oneLongSentence);
  });

  test('text exactly at the cap stays a single chunk', () {
    final exact = 'a' * cap;
    expect(TruxVoiceController.ttsChunks(exact), [exact]);
  });

  // Currency/percent were read digit-by-digit or garbled by on-device TTS
  // because of the $ + thousands-commas. forSpeech rewrites them into words.
  group('forSpeech number normalization', () {
    String s(String x) => TruxVoiceController.forSpeech(x);

    test('currency with commas → "N dollars" (no \$, no commas)', () {
      expect(s('The rate is \$2,190.'), 'The rate is 2190 dollars.');
      expect(s('We grossed \$120,000 this week.'),
          'We grossed 120000 dollars this week.');
      expect(s('\$1,234,567 total'), '1234567 dollars total');
    });

    test('cents and singular dollar', () {
      expect(s('\$1,234.56'), '1234 dollars and 56 cents');
      expect(s('\$1'), '1 dollar');
      expect(s('\$0.99'), '0 dollars and 99 cents');
    });

    test('scale words: \$1.2M / \$120K / \$3 billion', () {
      expect(s('about \$1.2M'), 'about 1.2 million dollars');
      expect(s('\$120K'), '120 thousand dollars');
      expect(s('\$3 billion'), '3 billion dollars');
    });

    test('percent → "percent"', () {
      expect(s('OR is 94%'), 'OR is 94 percent');
      expect(s('up 6.5%'), 'up 6.5 percent');
    });

    test('bare thousands-commas (miles/counts) lose the comma', () {
      expect(s('ran 120,000 miles'), 'ran 120000 miles');
    });

    test('markdown symbols dropped', () {
      expect(s('**\$2,190**'), '2190 dollars');
    });

    test('load numbers (no comma) are left alone', () {
      expect(s('Load 1197 delivered'), 'Load 1197 delivered');
    });
  });
}
