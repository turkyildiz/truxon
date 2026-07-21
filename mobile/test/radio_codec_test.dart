import 'package:flutter_test/flutter_test.dart';

import 'package:truxon_companion/services/radio_codec.dart';

/// The radio wire format: what leaves one tablet must reassemble identically
/// on another (and on the dispatch web console).
void main() {
  test('ptt payload roundtrips frames byte-for-byte', () {
    final frames = [
      List<int>.generate(80, (i) => i % 256),
      List<int>.generate(63, (i) => (i * 7) % 256),
    ];
    final packed = packPtt('ike', 42, frames);
    final out = unpackPtt(packed)!;
    expect(out.user, 'ike');
    expect(out.seq, 42);
    expect(out.frames, frames);
  });

  test('corrupt payloads return null instead of throwing', () {
    expect(unpackPtt({'u': 'x'}), isNull);
    expect(unpackPtt({'u': 'x', 'q': 1, 'c': ['not-base64!!']}), isNull);
    expect(unpackPtt({'u': 1, 'q': 'x', 'c': []}), isNull);
  });

  test('framer rebuffers arbitrary mic chunk sizes into exact 20ms frames', () {
    final framer = PcmFramer();
    const frameBytes = radioFrameSamples * 2;
    // feed 2.5 frames as three odd-sized chunks
    final data = List<int>.generate((frameBytes * 2.5).toInt(), (i) => i % 256);
    final out = <List<int>>[];
    out.addAll(framer.add(data.sublist(0, 100)));
    out.addAll(framer.add(data.sublist(100, frameBytes + 50)));
    out.addAll(framer.add(data.sublist(frameBytes + 50)));
    expect(out.length, 2); // two whole frames; the half frame waits
    expect(out[0], data.sublist(0, frameBytes));
    expect(out[1], data.sublist(frameBytes, frameBytes * 2));
    // next chunk completes the third frame
    final rest = framer.add(List<int>.generate(frameBytes ~/ 2, (i) => 7));
    expect(rest.length, 1);
  });

  test('framer reset drops partial audio (no stale tail on next PTT)', () {
    final framer = PcmFramer();
    framer.add(List<int>.filled(100, 1));
    framer.reset();
    final frames = framer.add(List<int>.filled(radioFrameSamples * 2, 2));
    expect(frames.single.first, 2);
  });

  test('parseWav reads PCM16 mono and its sample rate', () {
    // hand-built minimal WAV: 4 samples @ 24000 Hz
    List<int> u16(int v) => [v & 0xff, (v >> 8) & 0xff];
    List<int> u32(int v) => [...u16(v & 0xffff), ...u16(v >> 16)];
    final samples = [100, -200, 32000, -32000];
    final data = <int>[];
    for (final s in samples) { data.addAll(u16(s & 0xffff)); }
    final wav = <int>[
      ...'RIFF'.codeUnits, ...u32(36 + data.length), ...'WAVE'.codeUnits,
      ...'fmt '.codeUnits, ...u32(16), ...u16(1), ...u16(1),
      ...u32(24000), ...u32(48000), ...u16(2), ...u16(16),
      ...'data'.codeUnits, ...u32(data.length), ...data,
    ];
    final parsed = parseWav(wav)!;
    expect(parsed.sampleRate, 24000);
    expect(parsed.samples, samples);
  });

  test('parseWav rejects junk', () {
    expect(parseWav([1, 2, 3]), isNull);
    expect(parseWav(List<int>.filled(100, 0)), isNull);
  });

  test('resampleTo48k doubles a 24k signal and preserves endpoints', () {
    final out = resampleTo48k([0, 1000, 2000, 3000], 24000);
    expect(out.length, 8);
    expect(out.first, 0);
    expect(out[2], 1000); // original samples land on even indices
    expect(out[4], 2000);
    expect(out[3], 1500); // interpolated midpoint
  });

  test('resampleTo48k passes 48k through untouched', () {
    expect(resampleTo48k([5, 6, 7], 48000), [5, 6, 7]);
  });
}
