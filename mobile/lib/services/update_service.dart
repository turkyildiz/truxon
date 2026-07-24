import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../i18n.dart';
import 'diag.dart';

/// Self-update (OTA). On launch the app fetches a small hosted `latest.json`:
///   { "versionCode": 3, "versionName": "1.0.2",
///     "apkUrl": "https://…/app-release.apk",
///     "sha256": "hex digest of the APK", "notes": "…" }
/// If versionCode is newer than the installed build, it offers to download and
/// install the APK — no app store, no USB. The download is refused unless its
/// SHA-256 matches the manifest's `sha256` (a missing field also refuses), so a
/// tampered or corrupted APK never reaches the installer. Install itself goes
/// through Android's package installer, which asks the user to confirm (and to
/// allow installs from this app the first time).
/// What to do with a fetched update manifest (see [evaluateUpdateManifest]).
enum UpdateDecision {
  /// Strictly newer, has an APK URL and a sha256 — offer it.
  install,

  /// Same or older build (downgrades are refused) or no APK URL — silently skip.
  notApplicable,

  /// Newer, but no sha256 to verify against — refuse and tell the user.
  unverifiable,
}

/// Hosts an update APK may be downloaded from. The manifest lives on GitHub
/// releases; its asset URLs redirect to *.githubusercontent.com, which the
/// http client follows after this check — the allowlist gates the URL we were
/// *told*, https-only, so a manifest pointing anywhere else is refused.
/// Honest limit: the sha256 comes from the same manifest, so a fully
/// compromised manifest host defeats both checks — only signing the manifest
/// out-of-band would close that; this narrows the surface, it doesn't seal it.
bool isAllowedApkUrl(String apkUrl) {
  final uri = Uri.tryParse(apkUrl);
  if (uri == null || uri.scheme != 'https') return false;
  return uri.host == 'github.com' ||
      uri.host == 'objects.githubusercontent.com' ||
      uri.host.endsWith('.githubusercontent.com');
}

/// The exact bytes the publish script signs — the security-critical manifest
/// fields, newline-joined in a fixed order. Both signer (publish-release.sh)
/// and verifier MUST build this string identically or every signature fails.
/// `notes` is deliberately excluded (cosmetic); everything that decides WHICH
/// build installs from WHERE is covered: version, url, checksum, rollout.
String canonicalManifestPayload(Map<String, dynamic> manifest) {
  final code = (manifest['versionCode'] as num?)?.toInt() ?? 0;
  final name = (manifest['versionName'] as String?) ?? '';
  final url = (manifest['apkUrl'] as String?) ?? '';
  final sha = ((manifest['sha256'] as String?) ?? '').trim();
  final pct = (manifest['rolloutPct'] as num?)?.toInt() ?? 100;
  return '$code\n$name\n$url\n$sha\n$pct';
}

/// Verify the manifest's Ed25519 `sig` (base64, 64 bytes) over
/// [canonicalManifestPayload] using [publicKeyB64] (base64, raw 32-byte key).
/// Returns false for a missing, malformed, or invalid signature — never throws,
/// so a hostile manifest can only ever DENY an update, not crash the check.
bool verifyManifestSignature(Map<String, dynamic> manifest, String publicKeyB64) {
  try {
    final sigB64 = (manifest['sig'] as String?)?.trim() ?? '';
    if (sigB64.isEmpty) return false;
    final sig = base64.decode(sigB64);
    final pub = base64.decode(publicKeyB64.trim());
    if (sig.length != 64 || pub.length != 32) return false;
    final msg = utf8.encode(canonicalManifestPayload(manifest));
    return ed.verify(ed.PublicKey(pub), Uint8List.fromList(msg), Uint8List.fromList(sig));
  } catch (_) {
    return false; // any parse/verify error is a refusal, not a crash
  }
}

/// Pure decision half of the update check, split out of
/// [UpdateService.checkAndPrompt] so it's unit-testable. Returns the parsed
/// manifest fields alongside the decision (sha256 normalized to lowercase hex).
///
/// R9 #151 — staged rollout: an optional manifest `rolloutPct` (0-100) gates
/// who is OFFERED the build. Each device holds a stable random bucket 0-99;
/// bucket < pct → offered. Absent/invalid pct means 100 (everyone), so old
/// manifests keep full reach; a device outside the wave just sees
/// notApplicable and picks the build up when the wave widens.
///
/// Manifest signing: when [signingPublicKeyB64] is non-empty, a valid Ed25519
/// signature over the canonical payload is MANDATORY — an unsigned or forged
/// manifest returns `unverifiable`, exactly like a bad checksum. This is the
/// out-of-band trust the sha256 can't provide (sha rides the same manifest).
({UpdateDecision decision, int latestCode, String apkUrl, String sha256Hex})
    evaluateUpdateManifest(Map<String, dynamic> manifest, int currentCode,
        {int rolloutBucket = 0, String signingPublicKeyB64 = ''}) {
  final latestCode = (manifest['versionCode'] as num?)?.toInt() ?? 0;
  final apkUrl = (manifest['apkUrl'] as String?) ?? '';
  final sha256Hex = ((manifest['sha256'] as String?) ?? '').trim().toLowerCase();
  final pctRaw = (manifest['rolloutPct'] as num?)?.toInt();
  final rolloutPct = (pctRaw == null || pctRaw < 0 || pctRaw > 100) ? 100 : pctRaw;
  final UpdateDecision decision;
  if (latestCode <= currentCode ||
      apkUrl.isEmpty ||
      rolloutBucket.clamp(0, 99) >= rolloutPct) {
    decision = UpdateDecision.notApplicable;
  } else if (sha256Hex.isEmpty || !isAllowedApkUrl(apkUrl)) {
    // No checksum, or the APK would come from a host we don't release on →
    // we can't trust the download, so don't offer it.
    decision = UpdateDecision.unverifiable;
  } else if (signingPublicKeyB64.isNotEmpty &&
      !verifyManifestSignature(manifest, signingPublicKeyB64)) {
    // A signing key is configured but the manifest isn't validly signed —
    // refuse. This is the door a compromised release host cannot walk through.
    decision = UpdateDecision.unverifiable;
  } else {
    decision = UpdateDecision.install;
  }
  return (
    decision: decision,
    latestCode: latestCode,
    apkUrl: apkUrl,
    sha256Hex: sha256Hex,
  );
}

class UpdateService {
  /// Stable per-device rollout bucket 0-99 (drawn once, then persisted) so a
  /// staged wave lands on the same tablets until the pct widens.
  static Future<int> _rolloutBucket() async {
    try {
      final sp = await SharedPreferences.getInstance();
      var b = sp.getInt('ota_rollout_bucket');
      if (b == null) {
        b = Random().nextInt(100);
        await sp.setInt('ota_rollout_bucket', b);
      }
      return b;
    } catch (_) {
      return 0; // prefs unreadable — device joins the first wave
    }
  }

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
      final m = evaluateUpdateManifest(j, currentCode,
          rolloutBucket: await _rolloutBucket(),
          signingPublicKeyB64: AppConfig.otaSigningPublicKey);
      if (m.decision == UpdateDecision.notApplicable) return;
      if (m.decision == UpdateDecision.unverifiable) {
        if (context.mounted) await _showVerifyFailed(context);
        return;
      }

      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('updateAvailable')),
          content: Text(
            tr('updateReady').replaceFirst('{v}', '${j['versionName'] ?? m.latestCode}') +
                ((j['notes'] as String?)?.isNotEmpty == true ? '\n\n${j['notes']}' : ''),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('later'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('updateNow'))),
          ],
        ),
      );
      if (go != true || !context.mounted) return;

      await _downloadAndInstall(context, m.apkUrl, m.latestCode, m.sha256Hex);
    } catch (e) {
      // Offline / bad manifest / etc. — updating is best-effort, never blocks use.
      Diag.log('update: check failed: $e');
    }
  }

  /// "This APK isn't the one we published" — shown when the manifest has no
  /// sha256 or the downloaded file doesn't match it. Nothing gets installed.
  static Future<void> _showVerifyFailed(BuildContext context) => showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('updateFailedTitle')),
          content: Text(tr('updateFailedBody')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('ok'))),
          ],
        ),
      );

  static Future<void> _downloadAndInstall(
    BuildContext context,
    String apkUrl,
    int code,
    String sha256Hex,
  ) async {
    final progress = ValueNotifier<double>(0);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(tr('downloadingUpdate')),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: p > 0 ? p : null),
              const SizedBox(height: 12),
              Text(p > 0 ? '${(p * 100).toStringAsFixed(0)}%' : tr('starting')),
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
    } catch (e) {
      Diag.log('update: download failed: $e');
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('updateDownloadFailed'))),
        );
      }
      return;
    }

    // Verify the download against the manifest's sha256 before installing.
    // Anything short of an exact match (tampering, truncation, MITM on the
    // download) discards the file — the installer never sees it.
    final digest = await sha256.bind(outFile.openRead()).first;
    if (digest.toString() != sha256Hex) {
      Diag.log('update: sha256 mismatch for build $code — discarded');
      try {
        await outFile.delete();
      } catch (_) {}
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      if (context.mounted) await _showVerifyFailed(context);
      return;
    }

    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    // Hand the APK to Android's package installer.
    final result = await OpenFilex.open(outFile.path,
        type: 'application/vnd.android.package-archive');
    if (result.type != ResultType.done && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('couldNotOpenInstaller')}: ${result.message}')),
      );
    }
  }
}
