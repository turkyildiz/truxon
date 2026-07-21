import 'package:flutter/material.dart';

import '../i18n.dart';
import '../services/api.dart';

/// Tablet-day DVIR: the pre/post-trip walkaround as a tap-through checklist.
/// Every item defaults to OK; tap to flag a defect. Defects (or an unsafe
/// verdict) file straight into the maintenance command center for review.
const dvirItems = [
  'brakes', 'lights', 'tires', 'mirrors', 'horn',
  'wipers', 'coupling', 'leaks', 'emergency_equipment', 'cargo_securement',
];

class DvirScreen extends StatefulWidget {
  const DvirScreen({super.key, required this.api});
  final CompanionApi api;

  @override
  State<DvirScreen> createState() => _DvirScreenState();
}

class _DvirScreenState extends State<DvirScreen> {
  List<Map<String, dynamic>> _trucks = [];
  int? _truckId;
  String _type = 'pre_trip';
  final Map<String, String> _items = {for (final i in dvirItems) i: 'ok'};
  final _odoCtl = TextEditingController();
  final _defectsCtl = TextEditingController();
  bool _safe = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.api.listTrucks().then((t) {
      if (mounted) setState(() => _trucks = t);
    }).catchError((e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  bool get _hasDefect =>
      _items.values.any((v) => v != 'ok') || _defectsCtl.text.trim().isNotEmpty || !_safe;

  Future<void> _submit() async {
    final truckId = _truckId;
    if (truckId == null || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.api.submitDvir(
        truckId: truckId,
        inspectionType: _type,
        items: _items,
        odometer: num.tryParse(_odoCtl.text),
        defects: _defectsCtl.text.trim(),
        safe: _safe,
      );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('dvirTitle'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: _truckId,
                  decoration: InputDecoration(labelText: tr('dvirTruck')),
                  items: [
                    for (final t in _trucks)
                      DropdownMenuItem(value: t['id'] as int, child: Text('${t['unit_number']}')),
                  ],
                  onChanged: (v) => setState(() => _truckId = v),
                ),
              ),
              const SizedBox(width: 12),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'pre_trip', label: Text(tr('dvirPre'))),
                  ButtonSegment(value: 'post_trip', label: Text(tr('dvirPost'))),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() => _type = s.first),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _odoCtl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('dvirOdometer')),
          ),
          const SizedBox(height: 12),
          Text(tr('dvirTapToFlag'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 4),
          for (final item in dvirItems)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 3),
              color: _items[item] == 'ok' ? null : Colors.red.withValues(alpha: 0.12),
              child: ListTile(
                dense: true,
                leading: Icon(
                  _items[item] == 'ok' ? Icons.check_circle : Icons.report_problem,
                  color: _items[item] == 'ok' ? Colors.green : Colors.red,
                ),
                title: Text(tr('dvir_$item')),
                trailing: Text(
                  _items[item] == 'ok' ? tr('dvirOk') : tr('dvirDefect'),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _items[item] == 'ok' ? Colors.green : Colors.red,
                  ),
                ),
                onTap: () => setState(
                    () => _items[item] = _items[item] == 'ok' ? 'defect' : 'ok'),
              ),
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _defectsCtl,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: tr('dvirNotes'),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          SwitchListTile(
            value: _safe,
            onChanged: (v) => setState(() => _safe = v),
            title: Text(tr('dvirSafe')),
            subtitle: !_safe
                ? Text(tr('dvirUnsafeNote'),
                    style: const TextStyle(color: Colors.red))
                : null,
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _truckId == null || _sending ? null : _submit,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: _hasDefect ? Colors.red : null,
            ),
            child: Text(
              _sending
                  ? '…'
                  : _hasDefect
                      ? tr('dvirSubmitDefect')
                      : tr('dvirSubmit'),
              style: const TextStyle(fontSize: 16),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
