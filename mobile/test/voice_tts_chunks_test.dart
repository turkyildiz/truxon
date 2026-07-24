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
}
