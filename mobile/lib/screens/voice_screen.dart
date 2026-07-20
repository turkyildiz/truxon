import 'package:flutter/material.dart';

import '../i18n.dart';
import '../services/api.dart';
import '../services/trux_voice.dart';

/// Feature 2 — Forest voice console. Big mic, live transcript, spoken
/// British replies, and confirm cards for any action Trux proposes.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key, required this.api});
  final CompanionApi api;

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  late final TruxVoiceController _c = TruxVoiceController(widget.api);

  @override
  void initState() {
    super.initState();
    _c.init();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Color _accent(BuildContext ctx) {
    switch (_c.state) {
      case VoiceState.listening:
        return Colors.redAccent;
      case VoiceState.thinking:
        return Colors.amber.shade700;
      case VoiceState.speaking:
        return Theme.of(ctx).colorScheme.primary;
      case VoiceState.idle:
        return Theme.of(ctx).colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final turns = _c.turns;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(child: Text(_c.statusLabel, style: Theme.of(context).textTheme.bodyMedium)),
                  Text(tr('handsFree')),
                  Switch(value: _c.handsFree, onChanged: _c.setHandsFree),
                  IconButton(
                    tooltip: tr('clear'),
                    onPressed: turns.isEmpty ? null : _c.clear,
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                ],
              ),
            ),
            Expanded(
              child: turns.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          tr('askTruxHint'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.grey),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: turns.length,
                      itemBuilder: (context, i) => _bubble(turns[i]),
                    ),
            ),
            if (_c.partial.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('“${_c.partial}”', style: const TextStyle(fontStyle: FontStyle.italic)),
              ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: GestureDetector(
                onTap: _c.toggleMic,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _accent(context),
                    boxShadow: [
                      BoxShadow(
                        color: _accent(context).withValues(alpha: 0.4),
                        blurRadius: _c.state == VoiceState.listening ? 28 : 10,
                        spreadRadius: _c.state == VoiceState.listening ? 6 : 1,
                      ),
                    ],
                  ),
                  child: Icon(
                    _c.state == VoiceState.speaking
                        ? Icons.graphic_eq
                        : _c.state == VoiceState.thinking
                            ? Icons.hourglass_top
                            : _c.state == VoiceState.listening
                                ? Icons.mic
                                : Icons.mic_none,
                    color: Colors.white,
                    size: 42,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _bubble(TruxTurn t) {
    final isYou = t.role == 'you';
    return Column(
      crossAxisAlignment: isYou ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          constraints: const BoxConstraints(maxWidth: 320),
          decoration: BoxDecoration(
            color: isYou ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isYou ? tr('you') : 'TRUX', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(t.text),
            ],
          ),
        ),
        for (final p in t.proposals) _proposalCard(p),
      ],
    );
  }

  Widget _proposalCard(Map<String, dynamic> p) {
    return Card(
      color: Colors.amber.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${tr('confirmColon')} ${p['tool']}', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('${p['summary'] ?? ''}', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(onPressed: () => _c.confirm(p), child: Text(tr('confirmBtn'))),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: () => _c.reject(p), child: Text(tr('cancel'))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
