import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api.dart';

/// R9 #145 — document wallet: the paper a roadside inspection or scale house
/// asks for, pulled from the office's own filing. Driver docs (CDL, med card)
/// plus truck road paperwork (registration, insurance, permits, IFTA).
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key, required this.api});
  final CompanionApi api;

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Map<String, dynamic>? _data;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _busy = true; _error = null; });
    try {
      final d = await widget.api.myWalletDocuments();
      if (!mounted) return;
      setState(() { _data = d; _busy = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = '$e'; _busy = false; });
    }
  }

  Future<void> _open(Map<String, dynamic> doc) async {
    final path = doc['storage_path'] as String?;
    if (path == null) return;
    try {
      final url = await widget.api.signedDocUrl(path);
      if (url != null) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not open: $e')));
      }
    }
  }

  List<Map<String, dynamic>> _docs(String key) =>
      (((_data?[key]) as List?) ?? []).cast<Map<String, dynamic>>();

  @override
  Widget build(BuildContext context) {
    final mine = _docs('driver_docs');
    final trucks = _docs('truck_docs');
    return Scaffold(
      appBar: AppBar(title: const Text('Document wallet')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? ListView(padding: const EdgeInsets.all(24), children: [
                    Text('Could not load: $_error'),
                  ])
                : ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      const _SectionHeader('My documents'),
                      if (mine.isEmpty)
                        const _EmptyNote(
                            'Nothing on file yet — the office adds CDL and med-card scans.'),
                      ...mine.map((d) => Card(
                            child: ListTile(
                              leading: const Icon(Icons.badge_outlined),
                              title: Text('${d['doc_type']}'),
                              subtitle: Text('${d['filename']} · ${d['uploaded']}'),
                              trailing: const Icon(Icons.open_in_new, size: 18),
                              onTap: () => _open(d),
                            ),
                          )),
                      const SizedBox(height: 8),
                      const _SectionHeader('Truck papers'),
                      if (trucks.isEmpty)
                        const _EmptyNote(
                            'No registration/insurance/permit scans on file yet.'),
                      ...trucks.map((d) => Card(
                            child: ListTile(
                              leading: const Icon(Icons.local_shipping_outlined),
                              title: Text('${d['doc_type']} — unit ${d['unit']}'),
                              subtitle: Text('${d['filename']} · ${d['uploaded']}'),
                              trailing: const Icon(Icons.open_in_new, size: 18),
                              onTap: () => _open(d),
                            ),
                          )),
                    ],
                  ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(8),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      );
}
