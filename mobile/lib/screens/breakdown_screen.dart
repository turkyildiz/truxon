import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../services/api.dart';

/// R9 #141 — breakdown report from the cab. One guided form instead of a
/// phone scramble: pick the truck, say what broke, whether it can move; the
/// app attaches GPS and rings dispatch through Do-Not-Disturb.
class BreakdownScreen extends StatefulWidget {
  const BreakdownScreen({super.key, required this.api});
  final CompanionApi api;

  @override
  State<BreakdownScreen> createState() => _BreakdownScreenState();
}

class _BreakdownScreenState extends State<BreakdownScreen> {
  List<Map<String, dynamic>> _trucks = [];
  int? _truckId;
  bool _drivable = false;
  bool _sending = false;
  final _desc = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.api.listTrucks().then((t) {
      if (mounted) setState(() => _trucks = t);
    });
  }

  @override
  void dispose() {
    _desc.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final truckId = _truckId;
    if (truckId == null || _sending) return;
    final desc = _desc.text.trim();
    if (desc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Say what broke first.')));
      return;
    }
    setState(() => _sending = true);
    double? lat, lon;
    try {
      final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium,
              timeLimit: Duration(seconds: 8)));
      lat = pos.latitude;
      lon = pos.longitude;
    } catch (_) {/* no GPS — report goes in without it */}
    try {
      final unit = _trucks
              .firstWhere((t) => t['id'] == truckId, orElse: () => {})['unit_number']
              ?.toString() ??
          '';
      await widget.api.reportBreakdown(
        truckId: truckId,
        unit: unit,
        description: desc,
        drivable: _drivable,
        lat: lat,
        lon: lon,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Reported. Dispatch has been alerted — stay safe.')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not send: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Report breakdown')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: scheme.errorContainer,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                  'If anyone is hurt or the truck is blocking traffic, call 911 first.',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _truckId,
            decoration: const InputDecoration(labelText: 'Truck'),
            items: [
              for (final t in _trucks)
                DropdownMenuItem(
                    value: t['id'] as int, child: Text('${t['unit_number']}')),
            ],
            onChanged: (v) => setState(() => _truckId = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            maxLines: 3,
            maxLength: 200,
            decoration: const InputDecoration(
              labelText: 'What broke?',
              hintText: 'e.g. blown steer tire, coolant leak, no power',
            ),
          ),
          SwitchListTile(
            title: const Text('Truck can still move'),
            subtitle: const Text('Off = stuck where it sits'),
            value: _drivable,
            onChanged: (v) => setState(() => _drivable = v),
          ),
          const SizedBox(height: 8),
          Text('Your GPS position is attached automatically.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
                padding: const EdgeInsets.symmetric(vertical: 16)),
            onPressed: _truckId == null || _sending ? null : _submit,
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.report_problem),
            label: Text(_sending ? 'Sending…' : 'Report breakdown'),
          ),
        ],
      ),
    );
  }
}
