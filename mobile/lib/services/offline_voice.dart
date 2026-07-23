import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'diag.dart';

/// Offline voice for dead zones (task #105): sherpa-onnx streaming zipformer
/// STT + Piper (VITS) TTS, fully on-device. Model packs (~105 MB total) are
/// fetched once from the NAS Funnel — the same public host that already serves
/// truck routing — sha256-pinned, then everything runs with airplane-grade
/// connectivity: the mic, the recognizer, and the voice never touch the
/// network again.
class OfflineVoice {
  static const _base = 'https://aida-nas.tail2c5ca.ts.net/models';
  static const _packs = [
    _Pack('stt-en-20m.zip',
        'cca519cbb5f7176dcf17bf01c1317ff92575c5cb1177a4c4a91a4a3c97cec07b',
        'stt', 'tokens.txt'),
    _Pack('tts-piper-amy-low.zip',
        '82fc97e6e3206e18c72f979815366beebd4ddf2a2c5a439281ce788fa9239d94',
        'tts', 'en_US-amy-low.onnx'),
  ];

  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OfflineTts? _tts;
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  bool _bindingsReady = false;

  bool get enginesReady => _recognizer != null && _tts != null;

  Future<Directory> _modelRoot() async {
    final sup = await getApplicationSupportDirectory();
    return Directory('${sup.path}/voice_models');
  }

  /// True when every pack's probe file is on disk (engines may still be cold).
  Future<bool> modelsPresent() async {
    final root = await _modelRoot();
    for (final p in _packs) {
      if (!File('${root.path}/${p.dir}/${p.probe}').existsSync()) return false;
    }
    return true;
  }

  /// Download + verify + unpack any missing pack. Call from a WiFi context —
  /// ~105 MB once. Progress is 0..1 across the total byte budget.
  Future<bool> downloadModels({void Function(double)? onProgress}) async {
    final root = await _modelRoot();
    root.createSync(recursive: true);
    var done = 0;
    for (final p in _packs) {
      final dir = Directory('${root.path}/${p.dir}');
      if (File('${dir.path}/${p.probe}').existsSync()) {
        done++;
        onProgress?.call(done / _packs.length);
        continue;
      }
      try {
        final resp = await http.get(Uri.parse('$_base/${p.zip}'))
            .timeout(const Duration(minutes: 10));
        if (resp.statusCode != 200) {
          Diag.log('offline-voice: ${p.zip} -> HTTP ${resp.statusCode}');
          return false;
        }
        final got = sha256.convert(resp.bodyBytes).toString();
        if (got != p.sha256) {
          Diag.log('offline-voice: ${p.zip} sha mismatch ($got)');
          return false;
        }
        // unpack into a temp dir, then atomically move into place so a killed
        // app mid-extract can never look "present"
        final tmp = Directory('${dir.path}.part');
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        tmp.createSync(recursive: true);
        final arch = ZipDecoder().decodeBytes(resp.bodyBytes);
        extractArchiveToDisk(arch, tmp.path);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        tmp.renameSync(dir.path);
        done++;
        onProgress?.call(done / _packs.length);
      } catch (e) {
        Diag.log('offline-voice: download ${p.zip} failed: $e');
        return false;
      }
    }
    return true;
  }

  /// Bring the engines up from the on-disk models. Cheap if already up.
  Future<bool> ensureEngines() async {
    if (enginesReady) return true;
    if (!await modelsPresent()) return false;
    final root = await _modelRoot();
    try {
      if (!_bindingsReady) {
        sherpa.initBindings();
        _bindingsReady = true;
      }
      final stt = '${root.path}/stt';
      _recognizer ??= sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: '$stt/encoder-epoch-99-avg-1.int8.onnx',
            decoder: '$stt/decoder-epoch-99-avg-1.int8.onnx',
            joiner: '$stt/joiner-epoch-99-avg-1.int8.onnx',
          ),
          tokens: '$stt/tokens.txt',
          numThreads: 2,
          modelType: 'zipformer',
        ),
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.2,
        rule2MinTrailingSilence: 1.0,
      ));
      final tts = '${root.path}/tts';
      _tts ??= sherpa.OfflineTts(sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: '$tts/en_US-amy-low.onnx',
            tokens: '$tts/tokens.txt',
            dataDir: '$tts/espeak-ng-data',
          ),
          numThreads: 2,
        ),
      ));
      return true;
    } catch (e) {
      Diag.log('offline-voice: engine init failed: $e');
      _recognizer = null;
      _tts = null;
      return false;
    }
  }

  /// One utterance: open the mic, stream PCM16@16k into the recognizer, stop
  /// at the endpoint (or [maxFor]), return the final text ('' if nothing).
  Future<String> listenOnce({
    void Function(String partial)? onPartial,
    Duration maxFor = const Duration(seconds: 25),
  }) async {
    if (!await ensureEngines()) return '';
    final rec = _recognizer!;
    final stream = rec.createStream();
    final doneText = Completer<String>();
    Timer? guard;

    Future<void> finish() async {
      if (doneText.isCompleted) return;
      guard?.cancel();
      await _micSub?.cancel();
      _micSub = null;
      try {
        await _rec.stop();
      } catch (_) {}
      while (rec.isReady(stream)) {
        rec.decode(stream);
      }
      final text = rec.getResult(stream).text.trim();
      stream.free();
      doneText.complete(text);
    }

    try {
      final mic = await _rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      guard = Timer(maxFor, finish);
      _micSub = mic.listen((chunk) {
        final i16 = Int16List.view(
            chunk.buffer, chunk.offsetInBytes, chunk.lengthInBytes ~/ 2);
        final f32 = Float32List(i16.length);
        for (var i = 0; i < i16.length; i++) {
          f32[i] = i16[i] / 32768.0;
        }
        stream.acceptWaveform(samples: f32, sampleRate: 16000);
        while (rec.isReady(stream)) {
          rec.decode(stream);
        }
        final partial = rec.getResult(stream).text.trim();
        if (partial.isNotEmpty) onPartial?.call(partial);
        if (rec.isEndpoint(stream)) finish();
      }, onDone: finish, onError: (_) => finish());
    } catch (e) {
      Diag.log('offline-voice: mic failed: $e');
      guard?.cancel();
      stream.free();
      return '';
    }
    return doneText.future;
  }

  Future<void> stopListening() async {
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _rec.stop();
    } catch (_) {}
  }

  /// Speak [text] through Piper. Returns when playback has been fed (the
  /// audio task drains asynchronously; sherpa generation is the slow part).
  Future<bool> speak(String text) async {
    if (!await ensureEngines()) return false;
    try {
      final audio = _tts!.generate(text: text, sid: 0, speed: 1.0);
      final samples = audio.samples;
      final pcm = Int16List(samples.length);
      for (var i = 0; i < samples.length; i++) {
        final v = (samples[i] * 32767.0).clamp(-32768.0, 32767.0);
        pcm[i] = v.toInt();
      }
      await FlutterPcmSound.setup(
          sampleRate: audio.sampleRate, channelCount: 1);
      FlutterPcmSound.start();
      FlutterPcmSound.feed(PcmArrayInt16(bytes: ByteData.view(pcm.buffer)));
      // rough drain time so callers can sequence speech naturally
      final secs = samples.length / audio.sampleRate;
      await Future.delayed(
          Duration(milliseconds: (secs * 1000).round() + 250));
      return true;
    } catch (e) {
      Diag.log('offline-voice: tts failed: $e');
      return false;
    }
  }

  void dispose() {
    _micSub?.cancel();
    _rec.dispose();
    _recognizer?.free();
    _tts?.free();
    _recognizer = null;
    _tts = null;
  }
}

class _Pack {
  const _Pack(this.zip, this.sha256, this.dir, this.probe);
  final String zip;
  final String sha256;
  final String dir;
  final String probe;
}
