import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'diag.dart';
import 'radio_codec.dart';
import 'radio_rx.dart';

/// One-app push-to-talk: Opus voice over the already-authenticated Supabase
/// Realtime socket (private topic radio:fleet). Replaces the Mumla +
/// Tailscale side apps — the RLS policies on realtime.messages are the door,
/// so a deactivated login loses the radio with everything else.
///
/// Half-duplex by convention: hold to talk, release to listen. Latency over
/// broadcast is a few hundred ms — walkie-talkie feel, by design.
class RadioService {
  RadioService._();
  static final RadioService instance = RadioService._();

  final ValueNotifier<String> status = ValueNotifier('off'); // off|connecting|online
  final ValueNotifier<List<String>> roster = ValueNotifier(const []);
  final ValueNotifier<String?> talking = ValueNotifier(null); // who's on air (remote)
  final ValueNotifier<bool> transmitting = ValueNotifier(false);

  RealtimeChannel? _channel;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  SimpleOpusEncoder? _encoder;
  SimpleOpusDecoder? _decoder;
  final PcmFramer _framer = PcmFramer();
  final List<List<int>> _pending = [];
  int _seq = 0;
  String _me = '';
  bool _audioReady = false;
  Timer? _talkingClear;

  // While the background RadioRx (foreground service) is alive it owns
  // playback; the UI keeps indicators only, so audio never plays twice.
  bool _bgOwnsPlayback = false;
  Timer? _bgCheck;

  Future<void> _refreshBgOwnership() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final ts = prefs.getInt(RadioRx.kAlive) ?? 0;
      _bgOwnsPlayback =
          DateTime.now().millisecondsSinceEpoch - ts < 150000; // ~2.5 ticks
    } catch (_) {/* keep last known state */}
  }

  Future<void> connect(String username) async {
    if (_channel != null) return;
    _me = username;
    status.value = 'connecting';
    await _refreshBgOwnership();
    _bgCheck?.cancel();
    _bgCheck = Timer.periodic(
        const Duration(seconds: 30), (_) => _refreshBgOwnership());
    try {
      if (!_audioReady) {
        initOpus(await opus_flutter.load());
        _encoder = SimpleOpusEncoder(
            sampleRate: radioSampleRate, channels: 1, application: Application.voip);
        _decoder = SimpleOpusDecoder(sampleRate: radioSampleRate, channels: 1);
        await FlutterPcmSound.setup(sampleRate: radioSampleRate, channelCount: 1);
        _audioReady = true;
      }
    } catch (e) {
      Diag.log('radio: audio init failed: $e');
      status.value = 'off';
      rethrow;
    }

    // self: true so the tablet that relays Forest's answer hears it too —
    // its own MIC echo stays suppressed by the user filter in _onPtt.
    final ch = Supabase.instance.client.channel(
      'radio:fleet',
      opts: const RealtimeChannelConfig(private: true, self: true),
    );
    ch
        .onBroadcast(event: 'ptt', callback: _onPtt)
        .onBroadcast(event: 'state', callback: _onState)
        .onPresenceSync((_) => _refreshRoster())
        .onPresenceJoin((_) => _refreshRoster())
        .onPresenceLeave((_) => _refreshRoster())
        .subscribe((s, err) async {
      if (s == RealtimeSubscribeStatus.subscribed) {
        status.value = 'online';
        await ch.track({'user': _me});
      } else if (s == RealtimeSubscribeStatus.channelError || s == RealtimeSubscribeStatus.closed) {
        Diag.log('radio: channel $s ${err ?? ''}');
        status.value = 'off';
      }
    });
    _channel = ch;
  }

  void _refreshRoster() {
    final ch = _channel;
    if (ch == null) return;
    final names = <String>{};
    for (final state in ch.presenceState()) {
      for (final p in state.presences) {
        final u = p.payload['user'];
        if (u is String && u.isNotEmpty) names.add(u);
      }
    }
    roster.value = names.toList()..sort();
  }

  void _onState(Map<String, dynamic> payload) {
    final u = payload['u'];
    final on = payload['on'];
    if (u is! String || u == _me) return;
    talking.value = on == true ? u : (talking.value == u ? null : talking.value);
  }

  void _onPtt(Map<String, dynamic> payload) {
    final msg = unpackPtt(payload);
    if (msg == null || msg.user == _me) return;
    if (transmitting.value) return; // half-duplex: our mic wins locally
    talking.value = msg.user;
    _talkingClear?.cancel();
    _talkingClear = Timer(const Duration(milliseconds: 600), () => talking.value = null);
    if (_bgOwnsPlayback) return; // background RadioRx is playing this already
    final dec = _decoder;
    if (dec == null) return;
    for (final frame in msg.frames) {
      try {
        final pcm = dec.decode(input: Uint8List.fromList(frame));
        FlutterPcmSound.feed(PcmArrayInt16(bytes: ByteData.view(pcm.buffer)));
      } catch (e) {
        Diag.log('radio: decode drop: $e'); // one bad frame never kills playback
      }
    }
  }

  Future<void> startTalking() async {
    final ch = _channel;
    final enc = _encoder;
    if (ch == null || enc == null || transmitting.value) return;
    if (!await _recorder.hasPermission()) {
      Diag.log('radio: mic permission missing');
      return;
    }
    transmitting.value = true;
    _framer.reset();
    _pending.clear();
    unawaited(ch.sendBroadcastMessage(event: 'state', payload: {'u': _me, 'on': true}));
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: radioSampleRate,
      numChannels: 1,
    ));
    _micSub = stream.listen((chunk) {
      for (final frame in _framer.add(chunk)) {
        try {
          final pcm = Int16List.view(Uint8List.fromList(frame).buffer);
          _pending.add(enc.encode(input: pcm));
        } catch (e) {
          Diag.log('radio: encode drop: $e');
        }
      }
      if (_pending.length >= framesPerMessage) {
        final batch = List<List<int>>.from(_pending.take(framesPerMessage));
        _pending.removeRange(0, framesPerMessage);
        unawaited(ch.sendBroadcastMessage(event: 'ptt', payload: packPtt(_me, _seq++, batch)));
      }
    });
  }

  Future<void> stopTalking() async {
    if (!transmitting.value) return;
    transmitting.value = false;
    await _micSub?.cancel();
    _micSub = null;
    await _recorder.stop();
    final ch = _channel;
    if (ch != null) {
      if (_pending.isNotEmpty) {
        unawaited(ch.sendBroadcastMessage(
            event: 'ptt', payload: packPtt(_me, _seq++, List.from(_pending))));
        _pending.clear();
      }
      unawaited(ch.sendBroadcastMessage(event: 'state', payload: {'u': _me, 'on': false}));
    }
  }

  /// Broadcast a pre-rendered voice clip (Forest's TTS answers) as if [user]
  /// keyed up: paced at real-time so receivers' buffers and Realtime rate
  /// limits see exactly the same shape as live talk.
  Future<void> broadcastVoice(String user, List<int> pcm48kMono) async {
    final ch = _channel;
    final enc = _encoder;
    if (ch == null || enc == null || pcm48kMono.isEmpty) return;
    // encode everything up front
    final frames = <List<int>>[];
    for (var off = 0; off + radioFrameSamples <= pcm48kMono.length; off += radioFrameSamples) {
      try {
        frames.add(enc.encode(
            input: Int16List.fromList(pcm48kMono.sublist(off, off + radioFrameSamples))));
      } catch (e) {
        Diag.log('radio: forest encode drop: $e');
      }
    }
    if (frames.isEmpty) return;
    unawaited(ch.sendBroadcastMessage(event: 'state', payload: {'u': user, 'on': true}));
    var seq = 0;
    for (var i = 0; i < frames.length; i += framesPerMessage) {
      final batch = frames.sublist(
          i, (i + framesPerMessage).clamp(0, frames.length));
      unawaited(ch.sendBroadcastMessage(event: 'ptt', payload: packPtt(user, seq++, batch)));
      await Future.delayed(Duration(milliseconds: 20 * batch.length));
    }
    unawaited(ch.sendBroadcastMessage(event: 'state', payload: {'u': user, 'on': false}));
  }

  Future<void> disconnect() async {
    await stopTalking();
    _bgCheck?.cancel();
    _bgCheck = null;
    final ch = _channel;
    _channel = null;
    if (ch != null) await Supabase.instance.client.removeChannel(ch);
    status.value = 'off';
    roster.value = const [];
    talking.value = null;
  }
}
