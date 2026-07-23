import 'package:flutter/material.dart';

import '../services/api.dart';
import '../services/doc_scan.dart';

/// R9 #142 — fuel receipt capture at the pump: pick the truck, scan the paper
/// (edge-detect + on-device OCR), and it files against the unit for the
/// IFTA/audit trail. Cash buys the card import never sees get captured too.
class FuelReceiptScreen extends StatefulWidget {
  const FuelReceiptScreen({super.key, required this.api});
  final CompanionApi api;

  @override
  State<FuelReceiptScreen> createState() => _FuelReceiptScreenState();
}

class _FuelReceiptScreenState extends State<FuelReceiptScreen> {
  List<Map<String, dynamic>> _trucks = [];
  int? _truckId;
  bool _sending = false;
  int _sentCount = 0;

  @override
  void initState() {
    super.initState();
    widget.api.listTrucks().then((t) {
      if (mounted) setState(() => _trucks = t);
    });
  }

  Future<void> _scan() async {
    final truckId = _truckId;
    if (truckId == null || _sending) return;
    try {
      final scan = await DocScan.capture();
      if (scan == null) return;
      setState(() => _sending = true);
      await widget.api.uploadFuelReceipt(
        truckId,
        scan.bytes,
        filename: scan.name,
        ocrText: scan.ocrText,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sentCount++;
      });
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Receipt filed to the truck.')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fuel receipt')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
              'Snap the paper receipt at the pump. It files against the truck '
              'for the fuel/IFTA paper trail — do it even for cash buys.'),
          const SizedBox(height: 16),
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
          const SizedBox(height: 24),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16)),
            onPressed: _truckId == null || _sending ? null : _scan,
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.local_gas_station),
            label: Text(_sending ? 'Uploading…' : 'Scan receipt'),
          ),
          if (_sentCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                  '$_sentCount receipt${_sentCount == 1 ? '' : 's'} filed this session.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
