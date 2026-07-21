import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../i18n.dart';
import '../services/alarms.dart';
import '../services/api.dart';
import '../services/diag.dart';
import '../services/push.dart';
import '../services/nps_service.dart';
import '../services/radio_rx.dart';
import '../services/tracking_service.dart';
import '../services/update_service.dart';
import 'dvir_screen.dart';
import 'loads_screen.dart';
import 'voice_screen.dart';
import 'radio_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  final _api = CompanionApi();
  final _tracking = TruxTrackingService.instance;
  Map<String, dynamic>? _profile;
  bool _trackingOn = false;
  bool _locationDenied = false;
  String? _error;
  int _tab = 0;

  // Latest status report from the tracking isolate (see _onTrackingData).
  int _queuedFixes = 0;
  bool _uploadAuthStale = false;

  // Keep-fresh cadence: well inside AuthRefresher.refreshSkew (10 min) so the
  // UI-side session never quietly expires now that the SDK auto-refresh is off.
  Timer? _keepFresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FlutterForegroundTask.addTaskDataCallback(_onTrackingData);
    _keepFresh = Timer.periodic(
        const Duration(minutes: 3), (_) => _api.pushFreshTokenToTracker());
    _bootstrap();
  }

  @override
  void dispose() {
    _keepFresh?.cancel();
    FlutterForegroundTask.removeTaskDataCallback(_onTrackingData);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The token the tracker holds expires ~1h after the UI last refreshed it,
  /// and while we're backgrounded nobody refreshes. Push a fresh one every
  /// time the driver comes back so queued fixes flush on the next tick. Also
  /// re-check location: this is the return path from the "Allow all the time"
  /// settings redirect (silent — the redirect nags only once per session).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _api.pushFreshTokenToTracker();
      if (_locationDenied) _startTracking();
    }
  }

  /// Status report from the tracking isolate (queue depth + auth health),
  /// sent every sample. Drives the "uploads paused" banner on the loads tab.
  void _onTrackingData(Object data) {
    if (data is! Map) return;
    final queued = (data['queued'] as num?)?.toInt() ?? 0;
    final stale = data['authStale'] == true;
    if (mounted) {
      setState(() {
        _queuedFixes = queued;
        _uploadAuthStale = stale;
      });
    }
    // Tracker says its token is stale and we're alive to fix it — do so now.
    if (stale) _api.pushFreshTokenToTracker();
  }

  Future<void> _bootstrap() async {
    try {
      _tracking.init();
      // Alarm + urgent-push plumbing — TRULY best-effort: a driver dismissing
      // a permission dialog throws PlatformException, and that must never
      // take down the whole app (emulator-verified failure mode).
      try {
        await Alarms.requestPermissions();
      } catch (e) {
        Diag.log('bootstrap: alarm perms: $e');
      }
      try {
        await PushService.init(_api);
      } catch (e) {
        Diag.log('bootstrap: push init: $e');
      }
      final p = await _api.profile();
      setState(() => _profile = p);
      // Hand the radio username to the background receiver (RadioRx) so it
      // can filter own-mic echo and show this driver on the fleet roster.
      final radioName = (p?['full_name'] as String?)?.isNotEmpty == true
          ? p!['full_name'] as String
          : (p?['username'] as String? ?? 'User');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(RadioRx.kUser, radioName);
      // Drivers share location continuously — always on, no toggle.
      if ((p?['role'] as String?) == 'driver') {
        await _startTracking();
      }
      // Self-update check (best-effort; prompts only if a newer APK is hosted).
      if (mounted) UpdateService.checkAndPrompt(context);
      // Quarterly NPS — drivers only, once per quarter, snoozable.
      if (mounted && (p?['role'] as String?) == 'driver') {
        NpsService.checkAndPrompt(context, _api);
      }
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  /// Start (and keep) always-on background location for a driver. Retries the
  /// permission prompt if it isn't granted yet; the driver has no way to turn
  /// this off inside the app. `ok` is honest: only a full "Allow all the time"
  /// grant clears the red banner (see TruxTrackingService.setTracking).
  Future<void> _startTracking() async {
    final ok = await _tracking.setTracking(true, context: context);
    try {
      await _api.setDuty(true);
    } catch (_) {/* duty flag is best-effort */}
    if (mounted) {
      setState(() {
        _trackingOn = ok;
        _locationDenied = !ok;
      });
    }
  }

  Future<void> _onTrackingHint(bool active) async {
    // Tracking is always on for drivers; ensure the service is running.
    if (!_trackingOn) await _startTracking();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      // Friendly error state with a retry — never a raw exception wall.
      final scheme = Theme.of(context).colorScheme;
      return Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off, size: 56, color: scheme.outline),
                  const SizedBox(height: 12),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () {
                      setState(() => _error = null);
                      _bootstrap();
                    },
                    child: Text(tr('retry')),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (_profile == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final role = _profile?['role'] as String? ?? '';
    final name = (_profile?['full_name'] as String?)?.isNotEmpty == true
        ? _profile!['full_name'] as String
        : (_profile?['username'] as String? ?? 'User');
    final isDriver = role == 'driver';

    final tabs = isDriver
        ? <Widget>[_loadsTab(), VoiceScreen(api: _api), RadioScreen(username: name, api: _api), _aboutTab(role, name)]
        : <Widget>[VoiceScreen(api: _api), RadioScreen(username: name, api: _api), _aboutTab(role, name)];

    final dests = isDriver
        ? [
            NavigationDestination(icon: const Icon(Icons.local_shipping), label: tr('loads')),
            NavigationDestination(icon: const Icon(Icons.mic_none), label: tr('trux')),
            NavigationDestination(icon: const Icon(Icons.record_voice_over), label: tr('radio')),
            NavigationDestination(icon: const Icon(Icons.info_outline), label: tr('about')),
          ]
        : [
            NavigationDestination(icon: const Icon(Icons.mic_none), label: tr('trux')),
            NavigationDestination(icon: const Icon(Icons.record_voice_over), label: tr('radio')),
            NavigationDestination(icon: const Icon(Icons.info_outline), label: tr('about')),
          ];

    final safeTab = _tab.clamp(0, tabs.length - 1);

    return WithForegroundTask(
      child: Scaffold(
        appBar: AppBar(
          title: Text(isDriver ? 'Forest Companion' : 'Forest'),
          actions: [
            IconButton(
              tooltip: tr('signOut'),
              onPressed: () => _api.signOut(),
              icon: const Icon(Icons.logout),
            ),
          ],
        ),
        body: IndexedStack(index: safeTab, children: tabs),
        bottomNavigationBar: NavigationBar(
          selectedIndex: safeTab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: dests,
        ),
      ),
    );
  }

  Widget _loadsTab() {
    return Column(
      children: [
        // Tablet day: pre/post-trip inspection one tap from the day's start.
        ListTile(
          dense: true,
          leading: const Icon(Icons.fact_check_outlined, color: Colors.indigo),
          title: Text(tr('dvirTitle')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => DvirScreen(api: _api)),
          ),
        ),
        const Divider(height: 1),
        if (_locationDenied)
          Material(
            color: Colors.red.withValues(alpha: 0.12),
            child: ListTile(
              leading: const Icon(Icons.location_off, color: Colors.red),
              title: Text(tr('locationRequired')),
              subtitle: Text(tr('enableAllowAllTime')),
              trailing: FilledButton(
                onPressed: _startTracking,
                child: Text(tr('enable')),
              ),
            ),
          )
        else
          ListTile(
            leading: const Icon(Icons.gps_fixed, color: Colors.green),
            title: Text(tr('sharingLocation')),
            subtitle: Text(tr('alwaysOn')),
          ),
        // Tracker is queuing fixes because its token went stale — the resume
        // handler / _onTrackingData push a fresh one, so this self-heals.
        if (_uploadAuthStale && _queuedFixes > 0)
          Material(
            color: Colors.orange.withValues(alpha: 0.15),
            child: ListTile(
              leading: const Icon(Icons.cloud_off, color: Colors.deepOrange),
              title: Text(tr('uploadsPaused')),
              dense: true,
            ),
          ),
        const Divider(height: 1),
        Expanded(child: LoadsScreen(api: _api, onTrackingHint: _onTrackingHint)),
      ],
    );
  }

  Widget _aboutTab(String role, String name) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('hello').replaceFirst('{name}', name),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text('${tr('role')}: $role'),
          const SizedBox(height: 16),
          const Text('Forest Companion'),
          Text(tr('aboutVoice')),
          Text(tr('aboutRadio')),
          if (role == 'driver') ...[
            Text(tr('aboutLoads')),
            Text(tr('aboutLocation')),
          ],
          const SizedBox(height: 24),
          // Read-only field log (Diag ring buffer) so tracking/upload problems
          // can be diagnosed on the driver's own device. Newest first.
          Text(tr('diagnostics'), style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Expanded(
            child: FutureBuilder<List<String>>(
              // Rebuilds (tab switches, tracker reports) re-read the log.
              future: Diag.read(),
              builder: (_, snap) {
                final lines = snap.data ?? const <String>[];
                if (lines.isEmpty) {
                  return Text(tr('noDiagnostics'),
                      style: const TextStyle(color: Colors.grey));
                }
                return Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: ListView.builder(
                    itemCount: lines.length,
                    itemBuilder: (_, i) => Text(
                      lines[lines.length - 1 - i],
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
