import 'package:flutter/material.dart';
import '../services/api.dart';
import '../services/gps_tracker.dart';
import 'loads_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _api = CompanionApi();
  late final GpsTracker _gps = GpsTracker(_api);
  Map<String, dynamic>? _profile;
  bool _onDuty = false;
  String? _error;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final p = await _api.profile();
      await _gps.loadPersisted();
      await _gps.start();
      setState(() => _profile = p);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _toggleDuty(bool v) async {
    try {
      await _api.setDuty(v);
      setState(() {
        _onDuty = v;
        _gps.trackingAllowed = v;
      });
      if (v) await _gps.flush();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  void dispose() {
    _gps.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final role = _profile?['role'] as String? ?? '';
    final name = (_profile?['full_name'] as String?)?.isNotEmpty == true
        ? _profile!['full_name'] as String
        : (_profile?['username'] as String? ?? 'User');

    return Scaffold(
      appBar: AppBar(
        title: Text(role == 'driver' ? 'My loads' : 'Trux Companion'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: () => _api.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : _profile == null
              ? const Center(child: CircularProgressIndicator())
              : role == 'driver'
                  ? Column(
                      children: [
                        SwitchListTile(
                          title: const Text('On duty'),
                          subtitle: Text(_onDuty ? 'GPS tracking every 60s' : 'Enable to share location when idle'),
                          value: _onDuty,
                          onChanged: _toggleDuty,
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: LoadsScreen(
                            api: _api,
                            onTrackingHint: (activeLoad) {
                              // Track when on duty OR has active load
                              _gps.trackingAllowed = _onDuty || activeLoad;
                            },
                          ),
                        ),
                      ],
                    )
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Hello, $name', style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 8),
                          Text('Role: $role'),
                          const SizedBox(height: 16),
                          const Text(
                            'Dispatcher / office tools (Trux voice agent) arrive in Phase 2. '
                            'Use the web TMS for dispatch today. Drivers should use a linked driver login.',
                          ),
                        ],
                      ),
                    ),
      bottomNavigationBar: role == 'driver'
          ? NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.local_shipping), label: 'Loads'),
                NavigationDestination(icon: Icon(Icons.info_outline), label: 'About'),
              ],
            )
          : null,
    );
  }
}
