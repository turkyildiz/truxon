import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/api.dart';
import '../services/diag.dart';
import '../services/push.dart';

/// R9 #149 — one-tap health check for the "my tablet isn't working" phone
/// call: app version, server reachability + latency, GPS permission + fix,
/// push availability, and the field log — with a copy button so the driver
/// can paste the whole picture into a message to the office.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, required this.api});
  final CompanionApi api;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _Check {
  _Check(this.name, this.ok, this.detail);
  final String name;
  final bool? ok; // null = running
  final String detail;
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  List<_Check> _checks = [];
  List<String> _log = [];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _checks = [];
    });
    final checks = <_Check>[];
    void add(_Check c) {
      checks.add(c);
      if (mounted) setState(() => _checks = List.of(checks));
    }

    try {
      final info = await PackageInfo.fromPlatform();
      add(_Check('App version', true, '${info.version}+${info.buildNumber}'));
    } catch (e) {
      add(_Check('App version', false, '$e'));
    }

    final sw = Stopwatch()..start();
    try {
      await widget.api.myDriverId();
      sw.stop();
      add(_Check('Server connection', true, '${sw.elapsedMilliseconds} ms'));
    } catch (e) {
      sw.stop();
      add(_Check('Server connection', false,
          'failed after ${sw.elapsedMilliseconds} ms: $e'));
    }

    try {
      final perm = await Geolocator.checkPermission();
      final always = perm == LocationPermission.always;
      add(_Check(
          'Location permission',
          always,
          always
              ? 'allow all the time'
              : '$perm — tracking needs "allow all the time"'));
    } catch (e) {
      add(_Check('Location permission', false, '$e'));
    }

    try {
      final svc = await Geolocator.isLocationServiceEnabled();
      add(_Check('GPS service', svc, svc ? 'on' : 'OFF — turn on location'));
    } catch (e) {
      add(_Check('GPS service', false, '$e'));
    }

    add(_Check('Push notifications', PushService.available,
        PushService.available ? 'registered' : 'not available on this build'));

    final log = await Diag.read();
    if (mounted) {
      setState(() {
        _log = log;
        _running = false;
      });
    }
  }

  Future<void> _copyAll() async {
    final b = StringBuffer('Truxon diagnostics\n');
    for (final c in _checks) {
      b.writeln('${c.ok == true ? 'OK ' : 'FAIL'} ${c.name}: ${c.detail}');
    }
    b.writeln('--- field log (newest last) ---');
    for (final l in _log.skip(_log.length > 60 ? _log.length - 60 : 0)) {
      b.writeln(l);
    }
    await Clipboard.setData(ClipboardData(text: b.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copied — paste it to the office.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
              tooltip: 'Copy report',
              onPressed: _checks.isEmpty ? null : _copyAll,
              icon: const Icon(Icons.copy_all)),
          IconButton(
              tooltip: 'Re-run',
              onPressed: _running ? null : _run,
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          ..._checks.map((c) => ListTile(
                dense: true,
                leading: Icon(
                  c.ok == true ? Icons.check_circle : Icons.error,
                  color: c.ok == true ? Colors.green : scheme.error,
                ),
                title: Text(c.name),
                subtitle: Text(c.detail),
              )),
          if (_running)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text('Field log (newest first)',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          if (_log.isEmpty)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('No log entries.', style: TextStyle(color: Colors.grey)),
            ),
          ..._log.reversed.take(100).map((l) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                child: Text(l,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              )),
        ],
      ),
    );
  }
}
