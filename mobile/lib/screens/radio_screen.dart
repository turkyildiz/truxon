import 'package:flutter/material.dart';

import '../i18n.dart';
import '../services/api.dart';
import '../services/forest_radio.dart';
import '../services/mumble.dart';
import '../services/radio_service.dart';

/// The "Radio" tab — native push-to-talk over the app's own Supabase
/// connection. One app, no Mumla, no Tailscale. Forest is on the net too:
/// hold the green button, ask, and the answer is broadcast to the whole
/// fleet. The old Mumla deep-link stays as a small fallback until the
/// native path is field-verified.
class RadioScreen extends StatefulWidget {
  const RadioScreen({super.key, this.username, this.api});
  final String? username;
  final CompanionApi? api;

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> {
  final _radio = RadioService.instance;
  ForestRadio? _forest;
  bool _asking = false;
  bool _forestBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final api = widget.api;
    if (api != null) _forest = ForestRadio(api);
    _connect();
  }

  Future<void> _askStart() async {
    final f = _forest;
    if (f == null || _forestBusy) return;
    final ok = await f.startListening();
    if (ok && mounted) setState(() => _asking = true);
  }

  Future<void> _askFinish() async {
    final f = _forest;
    if (f == null || !_asking) return;
    setState(() {
      _asking = false;
      _forestBusy = true;
    });
    try {
      await f.finishAndBroadcast();
    } finally {
      if (mounted) setState(() => _forestBusy = false);
    }
  }

  Future<void> _connect() async {
    setState(() => _error = null);
    try {
      await _radio.connect(widget.username ?? 'driver');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(
          [_radio.status, _radio.roster, _radio.talking, _radio.transmitting]),
      builder: (context, _) {
        final online = _radio.status.value == 'online';
        final tx = _radio.transmitting.value;
        final onAir = _radio.talking.value;
        final others = _radio.roster.value
            .where((u) => u != (widget.username ?? ''))
            .toList();
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(Icons.circle,
                      size: 12,
                      color: online
                          ? Colors.green
                          : _radio.status.value == 'connecting'
                              ? Colors.amber
                              : Colors.grey),
                  const SizedBox(width: 8),
                  Text(online
                      ? tr('radioOnline')
                      : _radio.status.value == 'connecting'
                          ? tr('radioConnecting')
                          : tr('radioOffline')),
                  const Spacer(),
                  if (!online)
                    TextButton(onPressed: _connect, child: Text(tr('retry'))),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                ),
              const SizedBox(height: 8),
              // Who's on the radio
              Expanded(
                child: others.isEmpty
                    ? Center(
                        child: Text(tr('radioAlone'),
                            style: const TextStyle(color: Colors.grey)))
                    : Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final u in others)
                            Chip(
                              avatar: Icon(
                                onAir == u ? Icons.graphic_eq : Icons.person,
                                size: 18,
                                color: onAir == u ? Colors.green : null,
                              ),
                              label: Text(u),
                              backgroundColor: onAir == u
                                  ? Colors.green.withValues(alpha: 0.15)
                                  : null,
                            ),
                        ],
                      ),
              ),
              if (onAir != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    tr('radioTalking').replaceFirst('{name}', onAir),
                    style: const TextStyle(
                        color: Colors.green, fontWeight: FontWeight.w600),
                  ),
                ),
              // The button: hold to talk, release to listen.
              GestureDetector(
                onTapDown: online ? (_) => _radio.startTalking() : null,
                onTapUp: (_) => _radio.stopTalking(),
                onTapCancel: () => _radio.stopTalking(),
                child: Container(
                  width: 190,
                  height: 190,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: !online
                        ? Colors.grey.shade400
                        : tx
                            ? Colors.red
                            : Colors.indigo,
                    boxShadow: tx
                        ? [
                            BoxShadow(
                                color: Colors.red.withValues(alpha: 0.5),
                                blurRadius: 28,
                                spreadRadius: 6)
                          ]
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(tx ? Icons.mic : Icons.mic_none,
                          size: 64, color: Colors.white),
                      Text(
                        tx ? tr('radioOnAirYou') : tr('radioHoldToTalk'),
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Ask Forest: hold, speak the question; the answer is broadcast
              // to the whole fleet as a 🌲 Forest transmission.
              if (_forest != null)
                GestureDetector(
                  onTapDown: online && !_forestBusy ? (_) => _askStart() : null,
                  onTapUp: (_) => _askFinish(),
                  onTapCancel: _askFinish,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(30),
                      color: !online || _forestBusy
                          ? Colors.grey.shade400
                          : _asking
                              ? Colors.green.shade700
                              : Colors.green,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(_forestBusy ? Icons.hourglass_top : Icons.forest,
                            color: Colors.white, size: 22),
                        const SizedBox(width: 8),
                        Text(
                          _forestBusy
                              ? tr('radioForestThinking')
                              : _asking
                                  ? tr('radioForestListening')
                                  : tr('radioAskForest'),
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              // Transitional fallback: the old Mumla path, until field-verified.
              TextButton(
                onPressed: () => MumbleRadio.openRadio(username: widget.username),
                child: Text(tr('radioMumlaFallback'),
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            ],
          ),
        );
      },
    );
  }
}
