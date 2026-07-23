@Tags(['models'])
library;

// Engine-level probe for the offline voice stack. Runs ONLY when
// TRUXON_VOICE_MODELS points at a directory containing the extracted packs
// (stt/ + tts/) — the models are 105 MB and live on the NAS Funnel, not in
// git, so CI and normal `flutter test` skip this silently.
//
//   TRUXON_VOICE_MODELS=/path/to/models flutter test --tags models \
//     test/offline_voice_engines_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

void main() {
  final root = Platform.environment['TRUXON_VOICE_MODELS'];
  if (root == null || !Directory('$root/stt').existsSync()) {
    test('offline voice engine probe (skipped — no models)', () {});
    return;
  }

  test('zipformer STT transcribes the bundled test wav', () {
    sherpa.initBindings();
    final rec = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: '$root/stt/encoder-epoch-99-avg-1.int8.onnx',
          decoder: '$root/stt/decoder-epoch-99-avg-1.int8.onnx',
          joiner: '$root/stt/joiner-epoch-99-avg-1.int8.onnx',
        ),
        tokens: '$root/stt/tokens.txt',
        modelType: 'zipformer',
      ),
    ));
    final wav = File('$root/test_wavs/0.wav').readAsBytesSync();
    // 16-bit mono PCM WAV, 16 kHz — skip the 44-byte header
    final pcm = Int16List.view(wav.buffer, 44, (wav.length - 44) ~/ 2);
    final f32 = Float32List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      f32[i] = pcm[i] / 32768.0;
    }
    final stream = rec.createStream();
    stream.acceptWaveform(samples: f32, sampleRate: 16000);
    stream.acceptWaveform(
        samples: Float32List(8000), sampleRate: 16000); // tail padding
    while (rec.isReady(stream)) {
      rec.decode(stream);
    }
    final text = rec.getResult(stream).text.trim().toLowerCase();
    stream.free();
    rec.free();
    expect(text, isNotEmpty);
    // reference transcript: "after early nightfall the yellow lamps would
    // light up here and there the squalid quarter of the brothels"
    expect(text, contains('yellow lamps'));
  });

  test('piper TTS generates audible audio', () {
    sherpa.initBindings();
    final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: '$root/tts/en_US-amy-low.onnx',
          tokens: '$root/tts/tokens.txt',
          dataDir: '$root/tts/espeak-ng-data',
        ),
      ),
    ));
    final audio = tts.generate(
        text: 'Load nineteen twelve is marked delivered.', sid: 0, speed: 1.0);
    tts.free();
    expect(audio.sampleRate, greaterThan(8000));
    expect(audio.samples.length, greaterThan(audio.sampleRate)); // > 1s
    final peak = audio.samples.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);
    expect(peak, greaterThan(0.05)); // actual signal, not silence
  });
}
