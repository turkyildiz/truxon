import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../format.dart';
import '../i18n.dart';
import '../services/api.dart';

/// ACCOUNTANT mobile home — work the phones from your phone. Priority-sorted
/// overdue customers with one-tap dial. Recording promises + sending dunning
/// stays on the web workroom; this is the "who do I chase, right now" list.
class CollectionsScreen extends StatefulWidget {
  const CollectionsScreen({super.key, required this.api});
  final CompanionApi api;

  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen> {
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _queue = [];
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
      final q = await widget.api.collectionsQueue();
      Map<String, dynamic>? s;
      try {
        s = await widget.api.acctSummary();
      } catch (_) {}
      if (mounted) setState(() { _queue = q; _summary = s; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
              if (_summary != null) _kpiStrip(scheme),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                child: Row(children: [
                  Icon(Icons.call, color: scheme.primary, size: 20),
                  const SizedBox(width: 8),
                  Text(tr('collCallQueue'),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  Text('${_queue.length}', style: TextStyle(color: scheme.onSurfaceVariant)),
                ]),
              ),
              if (_error != null)
                Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: TextStyle(color: scheme.error))),
              if (_queue.isEmpty && _error == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 60),
                  child: Center(child: Text(tr('collAllClear'))),
                ),
              for (final c in _queue) _customerCard(c, scheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kpiStrip(ColorScheme scheme) {
    final s = _summary!;
    Widget kpi(String label, String value, {Color? color}) => Expanded(
          child: Column(children: [
            Text(value, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: color)),
            Text(label, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ]),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(colors: [scheme.primaryContainer, scheme.secondaryContainer]),
      ),
      child: Row(children: [
        kpi(tr('collArTotal'), money(s['ar_total'] as num?)),
        kpi(tr('collPastDue'), money(s['ar_past_due'] as num?),
            color: (s['ar_past_due'] as num? ?? 0) > 0 ? Colors.red.shade700 : null),
        kpi('DSO', '${(s['dso'] as num?)?.round() ?? 0}'),
        kpi(tr('collUnbilled'), money(s['unbilled_total'] as num?)),
      ]),
    );
  }

  Widget _customerCard(Map<String, dynamic> c, ColorScheme scheme) {
    final name = c['company_name']?.toString() ?? '?';
    final phone = c['phone']?.toString();
    final overdue = c['overdue_total'] as num?;
    final oldest = (c['oldest_days'] as num?)?.round() ?? 0;
    final count = (c['overdue_count'] as num?)?.round() ?? 0;
    final pays = (c['avg_days_to_pay'] as num?)?.round();
    final hot = oldest >= 60;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 4),
                  Row(children: [
                    Text(money(overdue),
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: hot ? Colors.red.shade700 : scheme.onSurface)),
                    Text('  ·  $count ${tr('collInvoices')}',
                        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    '${tr('collOldest')} $oldest ${tr('collDays')}'
                    '${pays != null ? ' · ${tr('collPaysIn')} ~$pays${tr('collD')}' : ''}',
                    style: TextStyle(fontSize: 12, color: hot ? Colors.red.shade700 : scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (phone != null && phone.isNotEmpty)
              FilledButton.icon(
                onPressed: () => launchUrl(Uri.parse('tel:$phone')),
                icon: const Icon(Icons.call, size: 18),
                label: Text(tr('collCall')),
              ),
          ],
        ),
      ),
    );
  }
}
