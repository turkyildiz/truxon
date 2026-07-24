import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../config.dart';
import '../i18n.dart';
import 'api.dart';
import 'diag.dart';
import 'offline_brain.dart';
import 'offline_voice.dart';

enum VoiceState { idle, listening, thinking, speaking }

class TruxTurn {
  TruxTurn(this.role, this.text, {this.proposals = const []});
  final String role; // 'you' | 'trux'
  final String text;
  final List<Map<String, dynamic>> proposals;
}

/// Feature 2 — Forest as a spoken assistant with a warm, steady American voice.
///
/// On-device speech recognition (speech_to_text) captures the driver; the text
/// goes to the `trux-agent` edge function (same brain as the web chat, scoped
/// to the driver's permissions); the reply is spoken back through an en-US TTS
/// voice. No audio or LLM keys ever leave via the client — trux-agent owns that.
class TruxVoiceController extends ChangeNotifier {
  TruxVoiceController(this._api);

  final CompanionApi _api;
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  /// Dead-zone stack (task #105): on-device sherpa STT + Piper TTS + the
  /// offline intent brain. Engaged whenever the network is gone; queued work
  /// drains automatically when coverage returns.
  final OfflineVoice offline = OfflineVoice();
  bool offlineMode = false;

  final List<TruxTurn> turns = [];
  VoiceState state = VoiceState.idle;
  String partial = '';
  String? _sessionId;
  bool handsFree = false;
  bool _sttReady = false;
  bool _voiceReady = false;

  bool get isBusy => state != VoiceState.idle;

  Future<bool> _isOffline() async {
    try {
      final res = await Connectivity().checkConnectivity();
      return res.contains(ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  StreamSubscription<List<ConnectivityResult>>? _connSub;

  Future<void> init() async {
    // Offline pack: fetch silently on WiFi if missing; drain the dead-zone
    // queue every time coverage comes back.
    _maybeFetchModels();
    _connSub = Connectivity().onConnectivityChanged.listen((res) async {
      if (!res.contains(ConnectivityResult.none)) {
        offlineMode = false;
        final sent = await OfflineBrain.drain(_api);
        if (sent > 0) {
          turns.add(TruxTurn(
              'trux', 'Back in coverage — pushed $sent queued update${sent == 1 ? '' : 's'}.'));
          notifyListeners();
        }
        if (res.contains(ConnectivityResult.wifi)) _maybeFetchModels();
      }
    });
    // TTS — pick a warm American voice for Forest.
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setLanguage(AppConfig.truxVoiceLocale);
      await _tts.setPitch(1.0);
      await _tts.setSpeechRate(0.48); // measured, unhurried cadence
      await _selectAmericanVoice();
      // Completion is driven from _speak() (it awaits each chunk, then calls
      // _onSpeakDone once) — a per-utterance handler would fire mid-reply on the
      // first chunk of a chunked long answer and reopen the mic too early.
      _voiceReady = true;
    } catch (e) {
      _voiceReady = false;
      Diag.log('voice: tts init failed: $e');
    }
    // STT.
    try {
      _sttReady = await _stt.initialize(
        onStatus: _onSttStatus,
        onError: (e) => _onSttStatus('notListening'),
      );
    } catch (e) {
      _sttReady = false;
      Diag.log('voice: stt init failed: $e');
    }
    notifyListeners();
  }

  bool _fetchingModels = false;
  Future<void> _maybeFetchModels() async {
    if (_fetchingModels) return;
    _fetchingModels = true;
    try {
      if (await offline.modelsPresent()) return;
      final conn = await Connectivity().checkConnectivity();
      if (!conn.contains(ConnectivityResult.wifi)) return; // ~105 MB — WiFi only
      final ok = await offline.downloadModels();
      Diag.log('offline-voice: model fetch ${ok ? 'complete' : 'failed'}');
    } catch (e) {
      Diag.log('offline-voice: model fetch error: $e');
    } finally {
      _fetchingModels = false;
    }
  }

  Future<void> _selectAmericanVoice() async {
    try {
      final voices = (await _tts.getVoices) as List?;
      if (voices == null) return;
      final us = voices
          .map((v) => Map<String, dynamic>.from(v as Map))
          .where((v) => (v['locale'] ?? '').toString().toLowerCase().contains('en-us'))
          .toList();
      if (us.isEmpty) return;
      // Prefer a warm male American timbre when the engine exposes one.
      final male = us.firstWhere(
        (v) => (v['name'] ?? '').toString().toLowerCase().contains('male') ||
            (v['name'] ?? '').toString().toLowerCase().contains('en-us-x-iom') ||
            (v['name'] ?? '').toString().toLowerCase().contains('#male'),
        orElse: () => us.first,
      );
      await _tts.setVoice({
        'name': male['name'].toString(),
        'locale': male['locale'].toString(),
      });
    } catch (_) {/* engine without voice enumeration — language is enough */}
  }

  String get statusLabel {
    if (!_sttReady) return tr('micUnavailable');
    switch (state) {
      case VoiceState.idle:
        return handsFree ? tr('tapToSpeakHandsFree') : tr('tapMicSpeak');
      case VoiceState.listening:
        return tr('listening');
      case VoiceState.thinking:
        return tr('truxThinking');
      case VoiceState.speaking:
        return tr('truxSpeaking');
    }
  }

  // ---- listening ----
  Future<void> toggleMic() async {
    if (state == VoiceState.listening) {
      await _stt.stop();
      await offline.stopListening();
      if (offlineMode) {
        state = VoiceState.idle;
        notifyListeners();
      }
      return;
    }
    if (state == VoiceState.speaking) {
      await _tts.stop();
    }
    // Dead zone? Run the whole turn on-device (sherpa STT -> offline brain ->
    // Piper). Device STT/TTS often silently require Google servers, so the
    // offline pack is the only stack we trust without bars.
    offlineMode = await _isOffline() && await offline.ensureEngines();
    if (offlineMode) {
      partial = '';
      state = VoiceState.listening;
      notifyListeners();
      final text = await offline.listenOnce(onPartial: (p) {
        partial = p;
        notifyListeners();
      });
      if (text.isEmpty) {
        state = VoiceState.idle;
        notifyListeners();
        return;
      }
      turns.add(TruxTurn('you', text));
      partial = '';
      state = VoiceState.thinking;
      notifyListeners();
      final reply = await OfflineBrain.handle(text);
      turns.add(TruxTurn('trux', reply));
      state = VoiceState.speaking;
      notifyListeners();
      await offline.speak(reply);
      _onSpeakDone();
      return;
    }
    if (!_sttReady) {
      _sttReady = await _stt.initialize();
      if (!_sttReady) {
        notifyListeners();
        return;
      }
    }
    partial = '';
    state = VoiceState.listening;
    notifyListeners();
    await _stt.listen(
      onResult: (r) {
        partial = r.recognizedWords;
        notifyListeners();
        if (r.finalResult && partial.trim().isNotEmpty) {
          _ask(partial.trim());
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        // Long queries were getting cut off: 30s total capped a long dictation,
        // and a 3s mid-thought pause finalized early. Give room to breathe.
        listenFor: const Duration(seconds: 120),
        pauseFor: const Duration(seconds: 5),
      ),
    );
  }

  void _onSttStatus(String status) {
    if (status == 'done' || status == 'notListening') {
      if (state == VoiceState.listening) {
        state = VoiceState.idle;
        notifyListeners();
      }
    }
  }

  // ---- ask Trux ----
  Future<void> _ask(String text) async {
    turns.add(TruxTurn('you', text));
    partial = '';
    state = VoiceState.thinking;
    notifyListeners();
    try {
      final res = await _api.truxSend(sessionId: _sessionId, message: text);
      _sessionId = (res['session_id'] as String?) ?? _sessionId;
      final reply = (res['reply'] as String?)?.trim();
      final proposals = ((res['proposals'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final spoken = (reply == null || reply.isEmpty)
          ? tr('voiceNoResult')
          : reply;
      turns.add(TruxTurn('trux', spoken, proposals: proposals));
      await _speak(spoken);
    } catch (e) {
      // Cloud brain unreachable mid-turn (coverage dropped after the mic
      // opened): degrade to the offline brain instead of a bare error.
      if (await offline.ensureEngines()) {
        offlineMode = true;
        final reply = await OfflineBrain.handle(text);
        turns.add(TruxTurn('trux', reply));
        state = VoiceState.speaking;
        notifyListeners();
        await offline.speak(reply);
        _onSpeakDone();
        return;
      }
      turns.add(TruxTurn('trux', tr('voiceError')));
      await _speak(tr('voiceError'));
    }
  }

  Future<void> confirm(Map<String, dynamic> proposal) async {
    state = VoiceState.thinking;
    notifyListeners();
    try {
      final res = await _api.truxSend(
        sessionId: _sessionId,
        confirmToken: proposal['token'] as String?,
      );
      final msg = res['already_executed'] == true
          ? tr('voiceAlreadyDone')
          : tr('voiceDone').replaceFirst('{tool}', '${proposal['tool']}');
      turns.add(TruxTurn('trux', msg));
      await _speak(msg);
    } catch (e) {
      turns.add(TruxTurn('trux', tr('voiceCannotComplete')));
      await _speak(tr('voiceCannotComplete'));
    }
  }

  Future<void> reject(Map<String, dynamic> proposal) async {
    try {
      await _api.truxSend(sessionId: _sessionId, rejectToken: proposal['token'] as String?);
    } catch (e) {
      // Reject is best-effort — the proposal token just expires server-side.
      Diag.log('voice: reject failed: $e');
    }
    turns.add(TruxTurn('trux', tr('voiceCancelled')));
    notifyListeners();
  }

  // ---- speaking ----
  // On-device TTS (Android's engine) rejects/truncates strings past ~4000 chars,
  // so a long Forest reply was getting cut off. Speak it in sentence-sized
  // chunks: nothing hits the cap, and audio starts sooner. awaitSpeakCompletion
  // is on, so each speak() awaits — we drive completion here, not via a handler.
  static const int _ttsMaxChunk = 450;

  @visibleForTesting
  static List<String> ttsChunks(String text) => _ttsChunks(text);

  static List<String> _ttsChunks(String text) {
    final t = text.trim();
    if (t.length <= _ttsMaxChunk) return t.isEmpty ? const [] : [t];
    final out = <String>[];
    var buf = '';
    void flush() {
      if (buf.trim().isNotEmpty) out.add(buf.trim());
      buf = '';
    }
    for (var s in t.split(RegExp(r'(?<=[.!?])\s+'))) {
      s = s.trim();
      if (s.isEmpty) continue;
      // A single sentence longer than the cap → split it on word boundaries.
      while (s.length > _ttsMaxChunk) {
        flush();
        var cut = s.lastIndexOf(' ', _ttsMaxChunk);
        if (cut <= 0) cut = _ttsMaxChunk;
        out.add(s.substring(0, cut).trim());
        s = s.substring(cut).trim();
      }
      if (buf.isEmpty) {
        buf = s;
      } else if (buf.length + 1 + s.length <= _ttsMaxChunk) {
        buf = '$buf $s';
      } else {
        flush();
        buf = s;
      }
    }
    flush();
    return out;
  }

  Future<void> _speak(String text) async {
    state = VoiceState.speaking;
    notifyListeners();
    if (!_voiceReady) {
      _onSpeakDone();
      return;
    }
    try {
      for (final chunk in _ttsChunks(text)) {
        if (state != VoiceState.speaking) break; // stopped/cancelled mid-reply
        await _tts.speak(chunk);
      }
    } catch (_) {
      // fall through to _onSpeakDone
    }
    _onSpeakDone();
  }

  void _onSpeakDone() {
    state = VoiceState.idle;
    notifyListeners();
    if (handsFree) {
      // Small courtesy pause, then reopen the mic for a natural back-and-forth.
      Future.delayed(const Duration(milliseconds: 400), () {
        if (state == VoiceState.idle && handsFree) toggleMic();
      });
    }
  }

  void setHandsFree(bool v) {
    handsFree = v;
    notifyListeners();
  }

  void clear() {
    turns.clear();
    _sessionId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _stt.stop();
    _tts.stop();
    _connSub?.cancel();
    offline.dispose();
    super.dispose();
  }
}
