import 'dart:async';

import 'package:flutter/material.dart';
import '../services/doc_scan.dart';
import '../services/offline_brain.dart';
import '../theme.dart';
import 'map_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../i18n.dart';
import '../services/api.dart';

class LoadsScreen extends StatefulWidget {
  const LoadsScreen({super.key, required this.api, this.onTrackingHint});

  final CompanionApi api;
  final void Function(bool hasActiveLoad)? onTrackingHint;

  @override
  State<LoadsScreen> createState() => _LoadsScreenState();
}

class _LoadsScreenState extends State<LoadsScreen> {
  List<DriverLoad> _loads = [];
  Map<String, dynamic>? _week;
  bool _loading = true;
  String? _error;

  /// "My week" strip above the load list — the driver's own numbers only.
  Widget _weekCard() {
    final w = _week;
    if (w == null || (w['loads'] as num? ?? 0) == 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    Widget stat(String label, String value) => Expanded(
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      color: scheme.onPrimaryContainer)),
              const SizedBox(height: 2),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.7))),
            ],
          ),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.secondaryContainer],
        ),
      ),
      child: Column(
        children: [
          Text(tr('myWeekTitle'),
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                  color: scheme.onPrimaryContainer)),
          const SizedBox(height: 10),
          Row(
            children: [
              stat(tr('myWeekLoads'), '${w['loads']}'),
              stat(tr('myWeekMiles'), '${(w['total_miles'] as num?)?.round() ?? 0}'),
              stat(tr('myWeekPay'), '\$${(w['est_pay'] as num?)?.round() ?? 0}'),
              if (w['on_time_pct'] != null) stat(tr('myWeekOnTime'), '${(w['on_time_pct'] as num).round()}%'),
              if ((w['detention_hours'] as num? ?? 0) > 0)
                stat(tr('myWeekDetention'), '${w['detention_hours']}h'),
            ],
          ),
        ],
      ),
    );
  }

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
      await _replayOutbox();
      final loads = await widget.api.myLoads();
      // dead-zone brain reads this cache when there's no signal to fetch with
      unawaited(OfflineBrain.cacheLoads(loads));
      final active = loads.any((l) => l.status == 'assigned' || l.status == 'in_transit');
      widget.onTrackingHint?.call(active);
      Map<String, dynamic>? week;
      try {
        week = await widget.api.myWeekScorecard();
      } catch (_) {} // the card is a bonus — never block the load list
      setState(() {
        _loads = loads;
        _week = week;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _replayOutbox() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('status_outbox');
    final items = OfflineOutbox.decode(raw);
    if (items.isEmpty) return;
    final remaining = await OfflineOutbox.replay(
      items,
      (item) => widget.api.changeStatus(item['load_id'] as int, item['status'] as String),
    );
    await prefs.setString('status_outbox', OfflineOutbox.encode(remaining));
  }

  Future<void> _queueOrSendStatus(DriverLoad load, String next) async {
    try {
      await widget.api.changeStatus(load.id, next);
      await _refresh();
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      final items = OfflineOutbox.decode(prefs.getString('status_outbox'));
      items.add({'load_id': load.id, 'status': next, 'queued_at': DateTime.now().toIso8601String()});
      await prefs.setString('status_outbox', OfflineOutbox.encode(items));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${tr('queuedOffline')}: $next ($e)')),
        );
      }
    }
  }

  String? _nextStatus(String status) {
    if (status == 'assigned') return 'in_transit';
    if (status == 'in_transit') return 'delivered';
    return null;
  }

  String _label(String status) {
    if (status == 'assigned') return tr('startTrip');
    if (status == 'in_transit') return tr('markDelivered');
    return status;
  }

  int? _uploadingFor;

  /// Feature 3 — snap a delivery receipt / BOL / POD and attach it to the load.
  Future<void> _capturePod(DriverLoad load) async {
    final docType = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(tr('whatPhotographing'))),
            for (final t in [
              ['pod', tr('docPod')],
              ['bol', tr('docBol')],
              ['receipt', tr('docReceipt')],
              ['lumper', tr('docLumper')],
              ['scale', tr('docScale')],
              ['photo', tr('docPhoto')],
            ])
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(t[1]),
                onTap: () => Navigator.pop(ctx, t[0]),
              ),
          ],
        ),
      ),
    );
    if (docType == null) return;
    try {
      // Edge-detected scan with on-device OCR; camera fallback inside.
      final scan = await DocScan.capture();
      if (scan == null) return;
      setState(() => _uploadingFor = load.id);
      await widget.api.uploadReceipt(
        load.id,
        scan.bytes,
        docType: docType,
        filename: scan.name,
        contentType: 'image/jpeg',
        ocrText: scan.ocrText,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('sentToDispatch').replaceFirst('{doc}', docType.toUpperCase()))),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('uploadFailed')}: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploadingFor = null);
    }
  }

  Future<void> _openDocs(DriverLoad load) async {
    try {
      final docs = await widget.api.listDocuments(load.id);
      if (!mounted) return;
      if (docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('noDocuments'))));
        return;
      }
      await showModalBottomSheet(
        context: context,
        builder: (ctx) => ListView(
          children: docs.map((d) {
            return ListTile(
              title: Text((d['filename'] ?? d['doc_type'] ?? 'file') as String),
              subtitle: Text((d['doc_type'] ?? '') as String),
              onTap: () async {
                final path = d['storage_path'] as String?;
                if (path == null) return;
                final url = await widget.api.signedDocUrl(path);
                if (url != null) await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              },
            );
          }).toList(),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _refresh, child: Text(tr('retry'))),
          ],
        ),
      );
    }
    if (_loads.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          children: [
            const SizedBox(height: 120),
            Center(child: Text(tr('noLoadsDetail'))),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _loads.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          if (i == 0) return _weekCard();
          final load = _loads[i - 1];
          final next = _nextStatus(load.status);
          final scheme = Theme.of(context).colorScheme;
          Widget stop(IconData icon, Color color, String label, String addr) =>
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                                color: scheme.onSurfaceVariant)),
                        Text(addr,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ],
              );
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(load.loadNumber,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 18)),
                      ),
                      StatusPill(load.status),
                    ],
                  ),
                  if (load.customerName != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(load.customerName!,
                          style: TextStyle(
                              fontSize: 13, color: scheme.onSurfaceVariant)),
                    ),
                  const SizedBox(height: 12),
                  stop(Icons.trip_origin, scheme.primary, tr('puLabel'),
                      load.pickup),
                  Padding(
                    padding: const EdgeInsets.only(left: 8.5),
                    child: SizedBox(
                        height: 14,
                        child: VerticalDivider(
                            width: 1, color: scheme.outlineVariant)),
                  ),
                  stop(Icons.place, Colors.red.shade400, tr('delLabel'),
                      load.delivery),
                  if (load.truckUnit != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(children: [
                        Icon(Icons.local_shipping_outlined,
                            size: 16, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Text('${tr('truckLabel')}: ${load.truckUnit}',
                            style: TextStyle(
                                fontSize: 13, color: scheme.onSurfaceVariant)),
                      ]),
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (next != null)
                        FilledButton(
                          onPressed: () => _queueOrSendStatus(load, next),
                          child: Text(_label(load.status)),
                        ),
                      if (load.status == 'assigned' || load.status == 'in_transit')
                        OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => MapScreen(load: load, api: widget.api)),
                          ),
                          icon: const Icon(Icons.navigation_outlined, size: 18),
                          label: Text(tr('mapNavigate')),
                        ),
                      OutlinedButton(
                        onPressed: () => _openDocs(load),
                        child: Text(tr('paperwork')),
                      ),
                      OutlinedButton.icon(
                        onPressed: _uploadingFor == load.id ? null : () => _capturePod(load),
                        icon: _uploadingFor == load.id
                            ? const SizedBox(
                                width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.photo_camera, size: 18),
                        label: Text(_uploadingFor == load.id ? tr('sending') : tr('photoPod')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
