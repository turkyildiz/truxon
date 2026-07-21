import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../config.dart';
import 'api.dart';
import 'diag.dart';
import 'radio_codec.dart';
import 'radio_service.dart';

/// Forest on the radio net. Hold Ask-Forest → on-device STT captures the
/// question → trux-agent answers (radio mode: short spoken sentences) → the
/// reply is synthesized with the British voice and BROADCAST on radio:fleet
/// as a transmission from "🌲 Forest" — every tablet and the dispatch console
/// hears it, exactly like another driver keying up. The asking tablet does
/// all the work; no server-side audio exists.
class ForestRadio {
  ForestRadio(this._api);
  final CompanionApi _api;
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool _busy = false;
  String _heard = '';
  String? _sessionId;

  static const forestUser = '🌲 Forest';

  Future<bool> _init() async {
    if (_ready) return true;
    try {
      _ready = await _stt.initialize();
      await _tts.setLanguage(AppConfig.truxVoiceLocale);
      await _tts.setSpeechRate(0.52);
      await _tts.setPitch(1.0);
    } catch (e) {
      Diag.log('forest-radio: init failed: $e');
      _ready = false;
    }
    return _ready;
  }

  bool get busy => _busy;

  /// Hold: start listening for the question.
  Future<bool> startListening() async {
    if (_busy || !await _init()) return false;
    _heard = '';
    await _stt.listen(
      onResult: (r) => _heard = r.recognizedWords,
      listenOptions: SpeechListenOptions(partialResults: true),
    );
    return true;
  }

  /// Release: stop listening, ask the agent, broadcast the spoken answer.
  /// Returns the transcript+reply for the screen, or null when nothing was
  /// heard / it failed (best-effort — the radio must never crash).
  Future<({String question, String reply})?> finishAndBroadcast() async {
    if (_busy) return null;
    _busy = true;
    try {
      await _stt.stop();
      // the recognizer finalizes shortly after stop
      await Future.delayed(const Duration(milliseconds: 400));
      final q = _heard.trim();
      if (q.isEmpty) return null;

      final res = await _api.truxSend(sessionId: _sessionId, message: q, radio: true);
      _sessionId = res['session_id'] as String? ?? _sessionId;
      final reply = (res['reply'] as String? ?? '').trim();
      if (reply.isEmpty) return null;

      await _broadcastSpoken(reply);
      return (question: q, reply: reply);
    } catch (e) {
      Diag.log('forest-radio: ask failed: $e');
      return null;
    } finally {
      _busy = false;
    }
  }

  Future<void> _broadcastSpoken(String text) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/forest-reply.wav';
    final f = File(path);
    if (await f.exists()) await f.delete();
    await _tts.synthesizeToFile(text, path, true);
    // the engine may finish writing slightly after the call resolves
    for (var i = 0; i < 20 && !await f.exists(); i++) {
      await Future.delayed(const Duration(milliseconds: 150));
    }
    if (!await f.exists()) {
      Diag.log('forest-radio: tts produced no file');
      return;
    }
    final wav = parseWav(await f.readAsBytes());
    if (wav == null) {
      Diag.log('forest-radio: unparseable tts wav');
      return;
    }
    final pcm = resampleTo48k(wav.samples, wav.sampleRate);
    await RadioService.instance.broadcastVoice(forestUser, pcm);
  }
}
