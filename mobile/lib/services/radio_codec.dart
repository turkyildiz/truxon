import 'dart:convert';

/// Wire format for the one-app radio (shared with the web dispatch console).
///
/// Topic: private Realtime channel `radio:fleet`.
/// Event `ptt`: `{u: <username>, q: <message seq>, c: [<base64 Opus frame>…]}`
///   Audio is 48 kHz mono Opus, 20 ms frames, [framesPerMessage] frames per
///   broadcast (100 ms cadence ≈ 10 messages/sec while talking — well inside
///   Realtime rate limits).
/// Event `state`: `{u: <username>, on: <bool>}` — talk start/stop for the UI.
///
/// This file is pure Dart (no plugins) so the framing logic is unit-testable.
const int radioSampleRate = 48000;
const int radioFrameSamples = 960; // 20 ms @ 48 kHz mono
const int framesPerMessage = 5; // 100 ms per broadcast

Map<String, dynamic> packPtt(String user, int seq, List<List<int>> opusFrames) => {
      'u': user,
      'q': seq,
      'c': [for (final f in opusFrames) base64Encode(f)],
    };

({String user, int seq, List<List<int>> frames})? unpackPtt(Map<String, dynamic> payload) {
  final u = payload['u'];
  final q = payload['q'];
  final c = payload['c'];
  if (u is! String || q is! num || c is! List) return null;
  try {
    return (
      user: u,
      seq: q.toInt(),
      frames: [for (final e in c) base64Decode(e as String)],
    );
  } catch (_) {
    return null; // corrupt frame batch — drop, never crash the radio
  }
}

/// Minimal RIFF/WAV reader for the TTS engine's output: returns 16-bit PCM
/// samples (first channel) + the file's sample rate. Returns null on
/// anything that isn't plain PCM16 WAV.
({List<int> samples, int sampleRate})? parseWav(List<int> bytes) {
  if (bytes.length < 44) return null;
  int u16(int o) => bytes[o] | (bytes[o + 1] << 8);
  int u32(int o) => u16(o) | (u16(o + 2) << 16);
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  int off = 12;
  int? rate;
  int channels = 1;
  int bits = 16;
  while (off + 8 <= bytes.length) {
    final id = tag(off);
    final size = u32(off + 4);
    if (id == 'fmt ') {
      if (u16(off + 8) != 1) return null; // PCM only
      channels = u16(off + 10);
      rate = u32(off + 12);
      bits = u16(off + 22);
    } else if (id == 'data' && rate != null) {
      if (bits != 16) return null;
      final end = (off + 8 + size).clamp(0, bytes.length);
      final samples = <int>[];
      final step = 2 * channels; // take channel 0 only
      for (var i = off + 8; i + 1 < end; i += step) {
        var s = bytes[i] | (bytes[i + 1] << 8);
        if (s >= 0x8000) s -= 0x10000;
        samples.add(s);
      }
      return (samples: samples, sampleRate: rate);
    }
    off += 8 + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

/// Linear resampler to [radioSampleRate] — voice-grade is all the radio
/// needs; TTS engines emit 22.05/24 kHz which Opus can't take directly.
List<int> resampleTo48k(List<int> samples, int fromRate) {
  if (fromRate == radioSampleRate || samples.isEmpty) return samples;
  final ratio = fromRate / radioSampleRate;
  final outLen = (samples.length / ratio).floor();
  final out = List<int>.filled(outLen, 0);
  for (var i = 0; i < outLen; i++) {
    final pos = i * ratio;
    final i0 = pos.floor();
    final i1 = (i0 + 1 < samples.length) ? i0 + 1 : i0;
    final frac = pos - i0;
    out[i] = (samples[i0] * (1 - frac) + samples[i1] * frac).round();
  }
  return out;
}

/// Accumulates raw PCM16 bytes from the mic stream and emits fixed
/// [radioFrameSamples]-sample frames for the encoder. Mic chunks arrive at
/// arbitrary sizes; this rebuffers them.
class PcmFramer {
  final List<int> _buf = [];

  List<List<int>> add(List<int> bytes) {
    _buf.addAll(bytes);
    final frames = <List<int>>[];
    const frameBytes = radioFrameSamples * 2; // 16-bit samples
    while (_buf.length >= frameBytes) {
      frames.add(List<int>.from(_buf.sublist(0, frameBytes)));
      _buf.removeRange(0, frameBytes);
    }
    return frames;
  }

  void reset() => _buf.clear();
}
