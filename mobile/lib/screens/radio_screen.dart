import 'package:flutter/material.dart';

import '../config.dart';
import '../i18n.dart';
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
          title: Text(tr('installRadioApp')),
          content: Text(tr('mumlaNotInstalled')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('later'))),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                MumbleRadio.openStore();
              },
              child: Text(tr('installMumla')),
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
            Text(tr('dispatchRadio'), style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(
              tr('radioSubtitle').replaceFirst(
                  '{server}', '${AppConfig.mumbleHost}:${AppConfig.mumblePort}'),
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
                label: Text(tr('connectToRadio'), style: const TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => MumbleRadio.openStore(),
              child: Text(tr('getMumla')),
            ),
            const SizedBox(height: 16),
            Text(
              tr('mumlaHint'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
