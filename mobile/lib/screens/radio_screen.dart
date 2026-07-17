import 'package:flutter/material.dart';

import '../config.dart';
import '../services/mumble.dart';

/// Feature 5 — the "Radio" tab: one big button that drops the driver into
/// Mumla connected to the dispatch server over the Tailscale VPN.
class RadioScreen extends StatelessWidget {
  const RadioScreen({super.key, this.username});
  final String? username;

  Future<void> _open(BuildContext context) async {
    final ok = await MumbleRadio.openRadio(username: username);
    if (!ok && context.mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Install the radio app'),
          content: const Text(
            'Push-to-talk uses Mumla. It looks like it isn\'t installed yet. '
            'Install it, then come back and tap Connect.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                MumbleRadio.openStore();
              },
              child: const Text('Install Mumla'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.record_voice_over, size: 72, color: Colors.indigo),
            const SizedBox(height: 12),
            Text('Dispatch radio', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(
              'Push-to-talk with the office over the private VPN.\n'
              'Server ${AppConfig.mumbleHost}:${AppConfig.mumblePort}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _open(context),
                icon: const Icon(Icons.settings_input_antenna),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 18)),
                label: const Text('Connect to radio', style: TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => MumbleRadio.openStore(),
              child: const Text('Get Mumla'),
            ),
            const SizedBox(height: 16),
            const Text(
              'In Mumla, map Push-to-Talk to a big on-screen button '
              '(Settings → Push to Talk).',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
