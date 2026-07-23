import 'package:flutter_test/flutter_test.dart';

import 'package:truxon_companion/services/update_service.dart';

/// The "is this manifest an applicable update" decision — the gate between a
/// hosted latest.json and the APK installer, so it must refuse downgrades and
/// anything we can't verify.
void main() {
  const sha = 'a3f5b8c9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b';

  Map<String, dynamic> manifest({Object? code, String? url, String? sha256}) => {
        'versionCode': ?code,
        'apkUrl': ?url,
        'sha256': ?sha256,
      };

  test('strictly newer versionCode with url + sha256 → install', () {
    final m = evaluateUpdateManifest(
        manifest(code: 4, url: 'https://github.com/x/app.apk', sha256: sha), 3);
    expect(m.decision, UpdateDecision.install);
    expect(m.latestCode, 4);
    expect(m.apkUrl, 'https://github.com/x/app.apk');
    expect(m.sha256Hex, sha);
  });

  test('equal versionCode → notApplicable', () {
    final m = evaluateUpdateManifest(
        manifest(code: 3, url: 'https://github.com/x/app.apk', sha256: sha), 3);
    expect(m.decision, UpdateDecision.notApplicable);
  });

  test('older versionCode (downgrade) → notApplicable', () {
    final m = evaluateUpdateManifest(
        manifest(code: 2, url: 'https://github.com/x/app.apk', sha256: sha), 3);
    expect(m.decision, UpdateDecision.notApplicable);
  });

  test('missing versionCode → notApplicable (treated as 0)', () {
    final m = evaluateUpdateManifest(
        manifest(url: 'https://github.com/x/app.apk', sha256: sha), 3);
    expect(m.decision, UpdateDecision.notApplicable);
  });

  test('missing apkUrl → notApplicable even when newer', () {
    final m = evaluateUpdateManifest(manifest(code: 4, sha256: sha), 3);
    expect(m.decision, UpdateDecision.notApplicable);
  });

  test('newer but missing sha256 → unverifiable, never install', () {
    final m =
        evaluateUpdateManifest(manifest(code: 4, url: 'https://github.com/x/app.apk'), 3);
    expect(m.decision, UpdateDecision.unverifiable);
  });

  test('newer but whitespace-only sha256 → unverifiable', () {
    final m = evaluateUpdateManifest(
        manifest(code: 4, url: 'https://github.com/x/app.apk', sha256: '   '), 3);
    expect(m.decision, UpdateDecision.unverifiable);
  });

  test('sha256 is normalized to trimmed lowercase hex', () {
    final m = evaluateUpdateManifest(
        manifest(code: 4, url: 'https://github.com/x/app.apk', sha256: '  ${sha.toUpperCase()} '), 3);
    expect(m.decision, UpdateDecision.install);
    expect(m.sha256Hex, sha);
  });

  test('versionCode sent as a double still compares as an int', () {
    final m = evaluateUpdateManifest(
        manifest(code: 4.0, url: 'https://github.com/x/app.apk', sha256: sha), 3);
    expect(m.decision, UpdateDecision.install);
    expect(m.latestCode, 4);
  });

  group('apkUrl origin allowlist', () {
    test('https github.com and githubusercontent hosts are allowed', () {
      expect(isAllowedApkUrl('https://github.com/x/app.apk'), isTrue);
      expect(isAllowedApkUrl('https://objects.githubusercontent.com/x.apk'), isTrue);
      expect(isAllowedApkUrl('https://release-assets.githubusercontent.com/x.apk'), isTrue);
    });

    test('http, other hosts, and lookalike suffixes are refused', () {
      expect(isAllowedApkUrl('http://github.com/x/app.apk'), isFalse);
      expect(isAllowedApkUrl('https://evil.example.com/app.apk'), isFalse);
      expect(isAllowedApkUrl('https://github.com.evil.example/app.apk'), isFalse);
      expect(isAllowedApkUrl('not a url'), isFalse);
    });

    test('newer manifest pointing off-host → unverifiable, never install', () {
      final m = evaluateUpdateManifest(
          manifest(code: 4, url: 'https://evil.example.com/app.apk', sha256: sha), 3);
      expect(m.decision, UpdateDecision.unverifiable);
    });
  });

  group('staged rollout (R9 #151)', () {
    Map<String, dynamic> staged(int pct) => {
          'versionCode': 4,
          'apkUrl': 'https://github.com/x/app.apk',
          'sha256': sha,
          'rolloutPct': pct,
        };

    test('bucket inside the wave is offered, outside is not', () {
      expect(evaluateUpdateManifest(staged(25), 3, rolloutBucket: 10).decision,
          UpdateDecision.install);
      expect(evaluateUpdateManifest(staged(25), 3, rolloutBucket: 25).decision,
          UpdateDecision.notApplicable);
      expect(evaluateUpdateManifest(staged(25), 3, rolloutBucket: 99).decision,
          UpdateDecision.notApplicable);
    });

    test('pct 0 offers nobody; pct 100 and absent offer everybody', () {
      expect(evaluateUpdateManifest(staged(0), 3, rolloutBucket: 0).decision,
          UpdateDecision.notApplicable);
      expect(evaluateUpdateManifest(staged(100), 3, rolloutBucket: 99).decision,
          UpdateDecision.install);
      expect(
          evaluateUpdateManifest(
              manifest(code: 4, url: 'https://github.com/x/app.apk', sha256: sha), 3,
              rolloutBucket: 99).decision,
          UpdateDecision.install);
    });

    test('invalid pct means full rollout, not a bricked wave', () {
      expect(evaluateUpdateManifest(staged(-5), 3, rolloutBucket: 99).decision,
          UpdateDecision.install);
      expect(evaluateUpdateManifest(staged(400), 3, rolloutBucket: 99).decision,
          UpdateDecision.install);
    });
  });
}
