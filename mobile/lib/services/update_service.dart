import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../config.dart';

/// Self-update (OTA). On launch the app fetches a small hosted `latest.json`:
///   { "versionCode": 3, "versionName": "1.0.2",
///     "apkUrl": "https://…/app-release.apk", "notes": "…" }
/// If versionCode is newer than the installed build, it offers to download and
/// install the APK — no app store, no USB. Install itself goes through Android's
/// package installer, which asks the user to confirm (and to allow installs
/// from this app the first time).
class UpdateService {
  /// Check silently; if a newer build exists, prompt. Never throws.
  static Future<void> checkAndPrompt(BuildContext context) async {
    if (AppConfig.updateManifestUrl.isEmpty) return;
    try {
      final info = await PackageInfo.fromPlatform();
      final currentCode = int.tryParse(info.buildNumber) ?? 0;

      final res = await http
          .get(Uri.parse(AppConfig.updateManifestUrl))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final latestCode = (j['versionCode'] as num?)?.toInt() ?? 0;
      final apkUrl = (j['apkUrl'] as String?) ?? '';
      if (latestCode <= currentCode || apkUrl.isEmpty) return;

      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Update available'),
          content: Text(
            'A newer version (${j['versionName'] ?? latestCode}) is ready.'
            '${(j['notes'] as String?)?.isNotEmpty == true ? '\n\n${j['notes']}' : ''}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Update now')),
          ],
        ),
      );
      if (go != true || !context.mounted) return;

      await _downloadAndInstall(context, apkUrl, latestCode);
    } catch (_) {
      // Offline / bad manifest / etc. — updating is best-effort, never blocks use.
    }
  }

  static Future<void> _downloadAndInstall(
    BuildContext context,
    String apkUrl,
    int code,
  ) async {
    final progress = ValueNotifier<double>(0);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Downloading update'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: p > 0 ? p : null),
              const SizedBox(height: 12),
              Text(p > 0 ? '${(p * 100).toStringAsFixed(0)}%' : 'Starting…'),
            ],
          ),
        ),
      ),
    );

    File? outFile;
    try {
      final dir = await getTemporaryDirectory();
      outFile = File('${dir.path}/trux-update-$code.apk');
      final req = http.Request('GET', Uri.parse(apkUrl));
      final resp = await http.Client().send(req);
      final total = resp.contentLength ?? 0;
      final sink = outFile.openWrite();
      var received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) progress.value = received / total;
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Update download failed — will retry next launch.')),
        );
      }
      return;
    }

    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    // Hand the APK to Android's package installer.
    final result = await OpenFilex.open(outFile.path,
        type: 'application/vnd.android.package-archive');
    if (result.type != ResultType.done && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open installer: ${result.message}')),
      );
    }
  }
}
