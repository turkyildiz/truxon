import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show
        RealtimeChannel,
        RealtimeChannelConfig,
        RealtimeClient,
        RealtimeSubscribeStatus;

import '../config.dart';
import 'auth_refresher.dart';
import 'diag.dart';
import 'radio_codec.dart';
import 'session_store.dart';

/// Always-on radio RECEIVER for the background service isolate.
///
/// The screen-side [RadioService] dies with the app; a CB radio must not. This
/// runs inside the same foreground service as GPS tracking, so incoming fleet
/// audio keeps playing with the screen off, another app up front, or the app
/// swiped away. Transmit stays in the UI (you need the button under a finger
/// anyway) over its own Realtime connection.
///
/// Follows the tracker's isolate rules: no Supabase.instance here — a
/// standalone [RealtimeClient] authenticated with the [SessionStore] token the
/// UI isolate hands over. Never refreshes tokens itself (single-refresher
/// rule, see SessionStore); when the token goes stale the channel drops and
/// rejoins on the tick after the UI stores a fresh one.
///
/// Cross-isolate contract with the UI radio:
///  * prefs [kUser]  — this driver's radio username (UI writes at login);
///    own transmissions are filtered out by name.
///  * prefs [kAlive] — heartbeat millis while the channel is joined; the UI
///    mutes ITS playback while this is fresh so audio never plays twice.
class RadioRx {
  static const kUser = 'radio_user';
  static const kAlive = 'radio_rx_alive';

  RealtimeClient? _client;
  RealtimeChannel? _channel;
  SimpleOpusDecoder? _decoder;
  bool _audioReady = false;
  bool _joined = false;
  String _me = '';
  String _trackedAs = ''; // presence name we last announced on the channel
  String? _lastToken;

  /// Called from the service tick (~every GPS interval) and once at start.
  /// Idempotent: connects when possible, re-auths on token change, heartbeats
  /// while healthy, and quietly waits out the gaps.
  Future<void> tick() async {
    try {
      // Single-path refresh: with the app closed this isolate becomes the
      // refresher (the prefs lock in AuthRefresher makes that safe), so the
      // radio and GPS run indefinitely, not just until the token expires.
      final token =
          await AuthRefresher.ensureFresh() ?? await SessionStore.accessToken();
      if (token == null || token.isEmpty) {
        await dispose(); // signed out — radio off with everything else
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      _me = prefs.getString(kUser) ?? _me;

      if (!_audioReady) {
        initOpus(await opus_flutter.load());
        _decoder = SimpleOpusDecoder(sampleRate: radioSampleRate, channels: 1);
        await FlutterPcmSound.setup(
            sampleRate: radioSampleRate, channelCount: 1);
        _audioReady = true;
      }

      if (_client == null) {
        final wsUrl =
            '${AppConfig.supabaseUrl.replaceFirst('http', 'ws')}/realtime/v1';
        _client = RealtimeClient(wsUrl,
            params: {'apikey': AppConfig.supabaseAnonKey});
        // No explicit connect(): the socket dials itself on first subscribe
        // (connect() is @internal in the v2 client).
      }
      if (token != _lastToken) {
        _client!.setAuth(token);
        _lastToken = token;
      }

      if (_channel == null) {
        final ch = _client!.channel(
          'radio:fleet',
          const RealtimeChannelConfig(private: true),
        );
        ch.onBroadcast(event: 'ptt', callback: _onPtt).subscribe((s, [err]) {
          if (s == RealtimeSubscribeStatus.subscribed) {
            _joined = true;
            Diag.log('radioRx: on air (background)');
          } else if (s == RealtimeSubscribeStatus.channelError ||
              s == RealtimeSubscribeStatus.closed) {
            _joined = false;
            _trackedAs = '';
            Diag.log('radioRx: channel $s ${err ?? ''}');
            // Drop the channel so the next tick rebuilds it clean (a stale
            // token error otherwise wedges the rejoin timer forever).
            _channel?.unsubscribe();
            _channel = null;
          }
        });
        _channel = ch;
      }

      Diag.log(
          'radioRx: tick joined=$_joined chan=${_channel?.isJoined}/${_channel?.isClosed} sock=${_client?.isConnected}');
      if (_joined) {
        // Presence: announce (and RE-announce) the driver on the roster.
        // After an OTA the service restarts BEFORE the app has written the
        // username pref — a one-shot track at subscribe left the tablet
        // invisible to the whole fleet until the next service restart.
        if (_me.isEmpty) {
          Diag.log('radioRx: no username yet — not on roster');
        }
        if (_me.isNotEmpty && _me != _trackedAs) {
          try {
            await _channel?.track({'user': _me});
            _trackedAs = _me;
            Diag.log('radioRx: on roster as $_me');
          } catch (e) {
            Diag.log('radioRx: presence track failed: $e');
          }
        }
        await prefs.setInt(kAlive, DateTime.now().millisecondsSinceEpoch);
      }
    } catch (e) {
      Diag.log('radioRx: tick failed: $e');
    }
  }

  void _onPtt(Map<String, dynamic> payload) {
    // The standalone RealtimeClient delivers the whole broadcast envelope
    // {type, event, payload:{u,q,c}} where the SDK-configured socket delivers
    // the inner payload directly — accept both shapes.
    var p = payload;
    if (p['u'] == null && p['payload'] is Map) {
      p = Map<String, dynamic>.from(p['payload'] as Map);
    }
    final msg = unpackPtt(p);
    if (msg == null || msg.user == _me) return; // own mic echo
    final dec = _decoder;
    if (dec == null) return;
    for (final frame in msg.frames) {
      try {
        final pcm = dec.decode(input: Uint8List.fromList(frame));
        FlutterPcmSound.feed(PcmArrayInt16(bytes: ByteData.view(pcm.buffer)));
      } catch (e) {
        Diag.log('radioRx: decode drop: $e');
      }
    }
  }

  Future<void> dispose() async {
    _joined = false;
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      try {
        await ch.unsubscribe();
      } catch (_) {}
    }
    final cl = _client;
    _client = null;
    _lastToken = null;
    if (cl != null) {
      try {
        cl.disconnect();
      } catch (_) {}
    }
  }
}
