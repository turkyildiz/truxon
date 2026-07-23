import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../i18n.dart';
import '../services/alarms.dart';
import '../services/api.dart';
import '../services/diag.dart';
import '../services/push.dart';
import '../services/push_prefs.dart';
import '../services/nps_service.dart';
import '../services/radio_rx.dart';
import '../services/tracking_service.dart';
import '../services/update_service.dart';
import 'breakdown_screen.dart';
import 'diagnostics_screen.dart';
import 'dvir_screen.dart';
import 'fuel_receipt_screen.dart';
import 'settlement_screen.dart';
import 'wallet_screen.dart';
import 'loads_screen.dart';
import 'voice_screen.dart';
import 'radio_screen.dart';
import 'dispatch_screen.dart';
import 'collections_screen.dart';
import 'command_screen.dart';
import '../services/forest_radio.dart';
import '../services/forest_copilot.dart';

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

  // Proactive Forest — drivers only. Speaks up on weather + stop arrival.
  ForestCopilot? _copilot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FlutterForegroundTask.addTaskDataCallback(_onTrackingData);
    _keepFresh = Timer.periodic(
        const Duration(minutes: 3), (_) => _api.pushFreshTokenToTracker());
    applyKioskPref(); // R9 #148: re-arm cab-mount wakelock across restarts
    _bootstrap();
  }

  @override
  void dispose() {
    _keepFresh?.cancel();
    _copilot?.stop();
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
        // Proactive co-pilot: speaks weather + arrival heads-ups to the driver.
        _copilot ??= ForestCopilot(_api, ForestRadio(_api))..start();
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
  /// Sign-out wipe: on a shared cab tablet the departing driver must leave
  /// nothing personal behind. signOut() already kills tracking + the GPS/status
  /// queues; here we also detach this device's push token (LOW) and clear the
  /// diagnostic log + radio username that otherwise survive to the next login.
  Future<void> _signOut() async {
    _copilot?.stop();
    _copilot = null;
    try {
      await PushService.unregisterCurrent(_api);
    } catch (_) {/* never block sign-out */}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(Diag.kLog);
      await prefs.remove(RadioRx.kUser);
    } catch (_) {}
    await _api.signOut();
  }

  Future<void> _startTracking() async {
    bool ok = false;
    try {
      ok = await _tracking.setTracking(true, context: context);
    } catch (e) {
      Diag.log('tracking: start failed: $e'); // degraded, never fatal
    }
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

    // Role-adaptive shell: mobile = command + awareness + the shared radio;
    // deep data entry stays on truxon.com. Everyone gets Forest + Radio + About;
    // the first "home" tab is what THAT role needs when away from the desk.
    final Widget roleHome;
    final NavigationDestination roleDest;
    switch (role) {
      case 'driver':
        roleHome = _loadsTab();
        roleDest = NavigationDestination(icon: const Icon(Icons.local_shipping), label: tr('loads'));
      case 'dispatcher':
        roleHome = DispatchScreen(api: _api);
        roleDest = NavigationDestination(icon: const Icon(Icons.dashboard_customize_outlined), label: tr('dispTab'));
      case 'accountant':
        roleHome = CollectionsScreen(api: _api);
        roleDest = NavigationDestination(icon: const Icon(Icons.request_quote_outlined), label: tr('collTab'));
      case 'admin':
        roleHome = CommandScreen(api: _api);
        roleDest = NavigationDestination(icon: const Icon(Icons.space_dashboard_outlined), label: tr('cmdTab'));
      default:
        roleHome = VoiceScreen(api: _api);
        roleDest = NavigationDestination(icon: const Icon(Icons.mic_none), label: tr('trux'));
    }
    final hasRoleHome = role == 'driver' || role == 'dispatcher' || role == 'accountant' || role == 'admin';

    final tabs = hasRoleHome
        ? <Widget>[roleHome, VoiceScreen(api: _api), RadioScreen(username: name, api: _api), _aboutTab(role, name)]
        : <Widget>[VoiceScreen(api: _api), RadioScreen(username: name, api: _api), _aboutTab(role, name)];

    final dests = hasRoleHome
        ? [
            roleDest,
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
            if (isDriver)
              IconButton(
                tooltip: 'Report breakdown',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => BreakdownScreen(api: _api)),
                ),
                icon: const Icon(Icons.report_problem_outlined),
              ),
            IconButton(
              tooltip: tr('signOut'),
              onPressed: _signOut,
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

  /// Compact tap target for the driver-home top row (bounded width, unlike a
  /// ListTile in a Row).
  Widget _quickAction(IconData icon, String label, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: scheme.primary),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _loadsTab() {
    final scheme = Theme.of(context).colorScheme;
    final content = Column(
      children: [
        // Tablet day: pre/post-trip inspection one tap from the day's start.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Row(children: [
            Expanded(
              child: Card(
                child: ListTile(
                  leading: Icon(Icons.fact_check_outlined, color: scheme.primary),
                  title: Text(tr('dvirTitle'),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => DvirScreen(api: _api)),
                  ),
                ),
              ),
            ),
            // R9 #143/#142: pay statement + fuel receipt, one tap each.
            _quickAction(Icons.payments_outlined, 'My Pay',
                () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => SettlementScreen(api: _api)))),
            _quickAction(Icons.local_gas_station, 'Fuel',
                () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => FuelReceiptScreen(api: _api)))),
            // R9 #145: the paper a roadside stop asks for.
            _quickAction(Icons.folder_shared_outlined, 'Wallet',
                () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => WalletScreen(api: _api)))),
          ]),
        ),
        if (_locationDenied)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Material(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(16),
              child: ListTile(
                leading: Icon(Icons.location_off, color: scheme.error),
                title: Text(tr('locationRequired'),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(tr('enableAllowAllTime')),
                trailing: FilledButton(
                  onPressed: _startTracking,
                  child: Text(tr('enable')),
                ),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 2),
            child: Row(
              children: [
                Icon(Icons.gps_fixed, size: 16, color: Colors.green.shade600),
                const SizedBox(width: 8),
                Text('${tr('sharingLocation')} — ${tr('alwaysOn')}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
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
        Expanded(child: LoadsScreen(api: _api, onTrackingHint: _onTrackingHint)),
      ],
    );
    // Tablets are wide; a reading-width column beats edge-to-edge banners.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: content,
      ),
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
          const SizedBox(height: 16),
          // R9 #149: live health checks + copyable report for support calls.
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => DiagnosticsScreen(api: _api)),
            ),
            icon: const Icon(Icons.health_and_safety_outlined),
            label: const Text('Run diagnostics'),
          ),
          const SizedBox(height: 8),
          // R9 #146: quiet the optional pushes; dispatch alarms always ring.
          const _NotificationPrefs(),
          // R9 #148: cab-mount mode — the tablet screen never sleeps.
          const _KioskToggle(),
          const SizedBox(height: 8),
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
                    // surface-relative so the log panel is visible in dark cabs too
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
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

/// R9 #148 — cab-mount ("kiosk") mode: keep the screen awake so a mounted
/// tablet stays on Forest all shift. Persisted; re-applied on app start by
/// [applyKioskPref].
class _KioskToggle extends StatefulWidget {
  const _KioskToggle();

  @override
  State<_KioskToggle> createState() => _KioskToggleState();
}

const kKioskPref = 'kiosk_keep_awake';

/// Re-apply the stored wakelock preference (called from app start).
Future<void> applyKioskPref() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(kKioskPref) ?? false) await WakelockPlus.enable();
  } catch (_) {/* cosmetic — never block startup */}
}

class _KioskToggleState extends State<_KioskToggle> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _on = p.getBool(kKioskPref) ?? false);
    });
  }

  Future<void> _set(bool v) async {
    setState(() => _on = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kKioskPref, v);
    try {
      if (v) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {/* device may not support it — the toggle stays honest */}
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: const Text('Cab-mount mode'),
      subtitle: const Text('Screen stays awake while the app is open',
          style: TextStyle(fontSize: 11)),
      value: _on,
      onChanged: _set,
    );
  }
}

/// R9 #146 — toggles for the optional push categories. New-assignment and
/// breakdown alarms are deliberately absent: those always ring.
class _NotificationPrefs extends StatefulWidget {
  const _NotificationPrefs();

  @override
  State<_NotificationPrefs> createState() => _NotificationPrefsState();
}

class _NotificationPrefsState extends State<_NotificationPrefs> {
  final Map<String, bool> _values = {};

  @override
  void initState() {
    super.initState();
    for (final type in PushPrefs.optional.keys) {
      PushPrefs.get(type).then((v) {
        if (mounted) setState(() => _values[type] = v);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('Notifications',
          style: Theme.of(context).textTheme.titleSmall),
      subtitle: const Text('Dispatch alarms always ring',
          style: TextStyle(fontSize: 11)),
      children: [
        for (final e in PushPrefs.optional.entries)
          SwitchListTile(
            dense: true,
            title: Text(e.value),
            value: _values[e.key] ?? true,
            onChanged: (v) {
              setState(() => _values[e.key] = v);
              PushPrefs.set(e.key, v);
            },
          ),
      ],
    );
  }
}
