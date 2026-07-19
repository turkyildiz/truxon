import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../config.dart';
import 'api.dart';
import 'diag.dart';

enum VoiceState { idle, listening, thinking, speaking }

class TruxTurn {
  TruxTurn(this.role, this.text, {this.proposals = const []});
  final String role; // 'you' | 'trux'
  final String text;
  final List<Map<String, dynamic>> proposals;
}

/// Feature 2 — Trux as a spoken assistant with a British, Jarvis-like voice.
///
/// On-device speech recognition (speech_to_text) captures the driver; the text
/// goes to the `trux-agent` edge function (same brain as the web chat, scoped
/// to the driver's permissions); the reply is spoken back through an en-GB TTS
/// voice. No audio or LLM keys ever leave via the client — trux-agent owns that.
class TruxVoiceController extends ChangeNotifier {
  TruxVoiceController(this._api);

  final CompanionApi _api;
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  final List<TruxTurn> turns = [];
  VoiceState state = VoiceState.idle;
  String partial = '';
  String? _sessionId;
  bool handsFree = false;
  bool _sttReady = false;
  bool _voiceReady = false;

  bool get isBusy => state != VoiceState.idle;

  Future<void> init() async {
    // TTS — pick a British voice for the Jarvis effect.
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setLanguage(AppConfig.truxVoiceLocale);
      await _tts.setPitch(1.0);
      await _tts.setSpeechRate(0.48); // measured, unhurried cadence
      await _selectBritishVoice();
      _tts.setCompletionHandler(_onSpeakDone);
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

  Future<void> _selectBritishVoice() async {
    try {
      final voices = (await _tts.getVoices) as List?;
      if (voices == null) return;
      final gb = voices
          .map((v) => Map<String, dynamic>.from(v as Map))
          .where((v) => (v['locale'] ?? '').toString().toLowerCase().contains('en-gb'))
          .toList();
      if (gb.isEmpty) return;
      // Prefer a male "Jarvis" timbre when the engine exposes one.
      final male = gb.firstWhere(
        (v) => (v['name'] ?? '').toString().toLowerCase().contains('male') ||
            (v['name'] ?? '').toString().toLowerCase().contains('en-gb-x-gbd') ||
            (v['name'] ?? '').toString().toLowerCase().contains('#male'),
        orElse: () => gb.first,
      );
      await _tts.setVoice({
        'name': male['name'].toString(),
        'locale': male['locale'].toString(),
      });
    } catch (_) {/* engine without voice enumeration — language is enough */}
  }

  String get statusLabel {
    if (!_sttReady) return 'Microphone unavailable — check permissions';
    switch (state) {
      case VoiceState.idle:
        return handsFree ? 'Tap to speak · hands-free on' : 'Tap the mic and speak';
      case VoiceState.listening:
        return 'Listening…';
      case VoiceState.thinking:
        return 'Trux is thinking…';
      case VoiceState.speaking:
        return 'Trux is speaking…';
    }
  }

  // ---- listening ----
  Future<void> toggleMic() async {
    if (state == VoiceState.listening) {
      await _stt.stop();
      return;
    }
    if (state == VoiceState.speaking) {
      await _tts.stop();
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
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 3),
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
          ? 'Sorry, I did not catch a result. Could you rephrase?'
          : reply;
      turns.add(TruxTurn('trux', spoken, proposals: proposals));
      await _speak(spoken);
    } catch (e) {
      turns.add(TruxTurn('trux', 'I hit an error reaching the office system.'));
      await _speak('I hit an error reaching the office system.');
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
          ? 'That was already done.'
          : 'Done — ${proposal['tool']} completed.';
      turns.add(TruxTurn('trux', msg));
      await _speak(msg);
    } catch (e) {
      turns.add(TruxTurn('trux', 'I could not complete that action.'));
      await _speak('I could not complete that action.');
    }
  }

  Future<void> reject(Map<String, dynamic> proposal) async {
    try {
      await _api.truxSend(sessionId: _sessionId, rejectToken: proposal['token'] as String?);
    } catch (e) {
      // Reject is best-effort — the proposal token just expires server-side.
      Diag.log('voice: reject failed: $e');
    }
    turns.add(TruxTurn('trux', 'Cancelled.'));
    notifyListeners();
  }

  // ---- speaking ----
  Future<void> _speak(String text) async {
    state = VoiceState.speaking;
    notifyListeners();
    if (!_voiceReady) {
      _onSpeakDone();
      return;
    }
    try {
      await _tts.speak(text);
    } catch (_) {
      _onSpeakDone();
    }
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
    super.dispose();
  }
}
