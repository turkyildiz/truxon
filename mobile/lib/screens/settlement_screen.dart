import 'package:flutter/material.dart';

import '../services/api.dart';

/// R9 #143/#144 — the driver's settlement statement: their own pay itemized
/// per load, week by week (26 weeks back). Estimated from their per-mile
/// rate; the banner says the office settlement is final.
class SettlementScreen extends StatefulWidget {
  const SettlementScreen({super.key, required this.api});
  final CompanionApi api;

  @override
  State<SettlementScreen> createState() => _SettlementScreenState();
}

class _SettlementScreenState extends State<SettlementScreen> {
  int _weekOffset = 0;
  Map<String, dynamic>? _data;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _busy = true; _error = null; });
    try {
      final d = await widget.api.mySettlement(_weekOffset);
      if (!mounted) return;
      setState(() { _data = d; _busy = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = '$e'; _busy = false; });
    }
  }

  void _shift(int delta) {
    final next = _weekOffset + delta;
    if (next < 0 || next > 26) return;
    setState(() => _weekOffset = next);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final loads = ((d?['loads'] as List?) ?? []).cast<Map<String, dynamic>>();
    return Scaffold(
      appBar: AppBar(title: const Text('My Pay')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(onPressed: _busy ? null : () => _shift(1), icon: const Icon(Icons.chevron_left)),
                Text(d?['week_label'] as String? ?? '…',
                    style: Theme.of(context).textTheme.titleMedium),
                IconButton(onPressed: _busy || _weekOffset == 0 ? null : () => _shift(-1), icon: const Icon(Icons.chevron_right)),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('Could not load: $_error', style: const TextStyle(color: Colors.redAccent)),
              )
            else if (_busy && d == null)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (d == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No driver record is linked to this login.', textAlign: TextAlign.center),
              )
            else ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text('\$${(d['total_pay'] as num? ?? 0).toStringAsFixed(2)}',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('${loads.length} load${loads.length == 1 ? '' : 's'} this week',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
              ...loads.map((l) => Card(
                    child: ListTile(
                      title: Text('${l['load_number'] ?? ''}  ·  ${l['lane'] ?? ''}'),
                      subtitle: Text(
                          'delivered ${l['delivered'] ?? ''}  ·  ${l['miles']} mi'
                          '${(l['empty_miles'] as num? ?? 0) > 0 ? ' + ${l['empty_miles']} empty' : ''}'),
                      trailing: Text('\$${(l['pay'] as num? ?? 0).toStringAsFixed(2)}',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  )),
              if (loads.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No completed loads this week.', textAlign: TextAlign.center),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(d['note'] as String? ?? '',
                    style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
