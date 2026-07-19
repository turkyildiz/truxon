import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
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
      await _replayOutbox();
      final loads = await widget.api.myLoads();
      final active = loads.any((l) => l.status == 'assigned' || l.status == 'in_transit');
      widget.onTrackingHint?.call(active);
      setState(() => _loads = loads);
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

  final _picker = ImagePicker();
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
      final shot = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 70,
        maxWidth: 2200,
      );
      if (shot == null) return;
      setState(() => _uploadingFor = load.id);
      final bytes = await shot.readAsBytes();
      await widget.api.uploadReceipt(
        load.id,
        bytes,
        docType: docType,
        filename: shot.name,
        contentType: shot.mimeType ?? 'image/jpeg',
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
        itemCount: _loads.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final load = _loads[i];
          final next = _nextStatus(load.status);
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(load.loadNumber, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                      Chip(label: Text(load.status)),
                    ],
                  ),
                  if (load.customerName != null) Text(load.customerName!),
                  const SizedBox(height: 6),
                  Text('${tr('puLabel')}: ${load.pickup}'),
                  Text('${tr('delLabel')}: ${load.delivery}'),
                  if (load.truckUnit != null) Text('${tr('truckLabel')}: ${load.truckUnit}'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (next != null)
                        FilledButton(
                          onPressed: () => _queueOrSendStatus(load, next),
                          child: Text(_label(load.status)),
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
