import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../i18n.dart';
import '../services/api.dart';

/// DISPATCHER mobile home — live fleet awareness in your pocket. Not the full
/// booking desk (that stays on the web); this is "where is everyone, who do I
/// call". Heavy work escalates to truxon.com; the radio (own tab) is how you
/// actually reach the trucks.
class DispatchScreen extends StatefulWidget {
  const DispatchScreen({super.key, required this.api});
  final CompanionApi api;

  @override
  State<DispatchScreen> createState() => _DispatchScreenState();
}

class _DispatchScreenState extends State<DispatchScreen> {
  List<Map<String, dynamic>> _fleet = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fleet = await widget.api.fleetPositions();
      if (mounted) setState(() => _fleet = fleet);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _ago(String? iso) {
    if (iso == null) return '—';
    final t = DateTime.tryParse(iso);
    if (t == null) return '—';
    final m = DateTime.now().toUtc().difference(t.toUtc()).inMinutes;
    if (m < 1) return tr('justNow');
    if (m < 60) return '${m}m';
    return '${(m / 60).floor()}h';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Row(
                children: [
                  Icon(Icons.dashboard_customize, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(tr('dispFleet'),
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  Text('${_fleet.length} ${tr('dispRolling')}',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 8),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_error!, style: TextStyle(color: scheme.error)),
                ),
              if (_fleet.isEmpty && _error == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 60),
                  child: Center(child: Text(tr('dispNoneRolling'))),
                ),
              for (final t in _fleet) _truckCard(t, scheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _truckCard(Map<String, dynamic> t, ColorScheme scheme) {
    final unit = t['truck_unit']?.toString() ?? '?';
    final driver = t['driver_name']?.toString() ?? tr('dispUnassigned');
    final loadNo = t['load_number']?.toString();
    final speed = (t['speed_mps'] as num?) ?? 0;
    final mph = (speed * 2.23694).round();
    final moving = mph > 3;
    final phone = t['driver_phone']?.toString();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: moving ? Colors.green.withValues(alpha: 0.15) : scheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.local_shipping,
                  color: moving ? Colors.green.shade700 : scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text('${tr('truckLabel')} $unit',
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    const SizedBox(width: 8),
                    if (loadNo != null)
                      Text('· $loadNo', style: TextStyle(color: scheme.onSurfaceVariant)),
                  ]),
                  Text(driver, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(
                    moving ? '$mph mph · ${_ago(t['recorded_at'] as String?)}' : '${tr('dispStopped')} · ${_ago(t['recorded_at'] as String?)}',
                    style: TextStyle(
                        fontSize: 12,
                        color: moving ? Colors.green.shade700 : scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (phone != null && phone.isNotEmpty)
              IconButton.filledTonal(
                icon: const Icon(Icons.call),
                onPressed: () => launchUrl(Uri.parse('tel:$phone')),
              ),
          ],
        ),
      ),
    );
  }
}
