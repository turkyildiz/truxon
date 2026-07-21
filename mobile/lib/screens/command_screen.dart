import 'package:flutter/material.dart';
import '../format.dart';
import '../i18n.dart';
import '../services/api.dart';

/// ADMIN/OWNER mobile home — the whole business, glanceable, away from the
/// desk. A/R KPI strip + the live Sentinel feed (money/cash/ops/compliance
/// findings) with one-tap acknowledge. Deep analysis stays on the web command
/// deck; Forest (own tab) answers anything this doesn't show.
class CommandScreen extends StatefulWidget {
  const CommandScreen({super.key, required this.api});
  final CompanionApi api;

  @override
  State<CommandScreen> createState() => _CommandScreenState();
}

class _CommandScreenState extends State<CommandScreen> {
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _insights = [];
  bool _loading = true;
  String? _error;
  final Set<int> _acking = {};

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
      final feed = await widget.api.insightsFeed();
      Map<String, dynamic>? s;
      try {
        s = await widget.api.acctSummary();
      } catch (_) {}
      if (mounted) setState(() { _insights = feed; _summary = s; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _ack(int id) async {
    setState(() => _acking.add(id));
    try {
      await widget.api.acknowledgeInsight(id);
      if (mounted) setState(() => _insights.removeWhere((i) => (i['id'] as num?)?.toInt() == id));
    } catch (_) {
    } finally {
      if (mounted) setState(() => _acking.remove(id));
    }
  }

  ({Color fg, Color bg, IconData icon}) _sev(BuildContext ctx, String severity, String category) {
    final dark = Theme.of(ctx).brightness == Brightness.dark;
    Color tone(MaterialColor c) => dark ? c.shade300 : c.shade700;
    Color tint(MaterialColor c) => dark ? c.shade900.withValues(alpha: 0.4) : c.shade50;
    final icon = switch (category) {
      'money' => Icons.attach_money,
      'cash' => Icons.account_balance_wallet,
      'compliance' => Icons.gpp_maybe,
      _ => Icons.insights,
    };
    return switch (severity) {
      'critical' => (fg: tone(Colors.red), bg: tint(Colors.red), icon: icon),
      'warn' => (fg: tone(Colors.orange), bg: tint(Colors.orange), icon: icon),
      _ => (fg: tone(Colors.blue), bg: tint(Colors.blue), icon: icon),
    };
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
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
                child: Row(children: [
                  Icon(Icons.notifications_active, color: scheme.primary, size: 20),
                  const SizedBox(width: 8),
                  Text(tr('cmdSentinel'),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  Text('${_insights.length}', style: TextStyle(color: scheme.onSurfaceVariant)),
                ]),
              ),
              if (_error != null)
                Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: TextStyle(color: scheme.error))),
              if (_insights.isEmpty && _error == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 60),
                  child: Center(child: Text(tr('cmdAllClear'))),
                ),
              for (final i in _insights) _insightCard(i, scheme),
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
        kpi(tr('cmdUnbilled'), money(s['unbilled_total'] as num?)),
        kpi('DSO', '${(s['dso'] as num?)?.round() ?? 0}'),
      ]),
    );
  }

  Widget _insightCard(Map<String, dynamic> i, ColorScheme scheme) {
    final id = (i['id'] as num?)?.toInt();
    final sev = _sev(context, i['severity']?.toString() ?? 'info', i['category']?.toString() ?? '');
    final acking = id != null && _acking.contains(id);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: sev.bg, borderRadius: BorderRadius.circular(10)),
              child: Icon(sev.icon, color: sev.fg, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(i['title']?.toString() ?? '',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  if ((i['detail']?.toString() ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(i['detail'].toString(),
                          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                    ),
                ],
              ),
            ),
            if (id != null)
              IconButton(
                tooltip: tr('cmdAck'),
                onPressed: acking ? null : () => _ack(id),
                icon: acking
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check_circle_outline),
              ),
          ],
        ),
      ),
    );
  }
}
