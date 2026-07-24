import 'dart:convert';

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

  group('manifest signing (Ed25519)', () {
    // Test vectors from a throwaway ed25519 key signing the canonical payload
    // for {code:4, name:1.0.2, url, sha, pct:100} — NOT the production key.
    const testPubKey = 'rmUqPgkHeraprhPkwM3YrW7r1gRFGef/UM7xTV41y2c=';
    const testSig =
        'HrDdPVa57c5K1vHqsQ8uorjI2LD0V730fRii823xUR24LyBzNNtcokAazbtWEMy6laVid8p4ilvaCOHu0/LNDQ==';

    Map<String, dynamic> signed({
      int code = 4,
      String name = '1.0.2',
      String url = 'https://github.com/x/app.apk',
      String sha256 = sha,
      int pct = 100,
      Object? sig = testSig,
    }) =>
        {
          'versionCode': code,
          'versionName': name,
          'apkUrl': url,
          'sha256': sha256,
          'rolloutPct': pct,
          'sig': ?sig,
        };

    test('valid signature with a key configured → install', () {
      final m = evaluateUpdateManifest(signed(), 3, signingPublicKeyB64: testPubKey);
      expect(m.decision, UpdateDecision.install);
    });

    test('missing signature with a key configured → unverifiable', () {
      final m = evaluateUpdateManifest(signed(sig: null), 3, signingPublicKeyB64: testPubKey);
      expect(m.decision, UpdateDecision.unverifiable);
    });

    test('a tampered versionName invalidates the signature → unverifiable', () {
      final m = evaluateUpdateManifest(signed(name: '9.9.9'), 3, signingPublicKeyB64: testPubKey);
      expect(m.decision, UpdateDecision.unverifiable);
    });

    test('a forged newer versionCode with the old signature → unverifiable', () {
      // the classic attack: bump the code to force a re-install of an old APK.
      final m = evaluateUpdateManifest(signed(code: 5), 3, signingPublicKeyB64: testPubKey);
      expect(m.decision, UpdateDecision.unverifiable);
    });

    test('a redirected apkUrl invalidates the signature → unverifiable', () {
      // url is on the allowlist (github) but not the one that was signed.
      final m = evaluateUpdateManifest(
          signed(url: 'https://github.com/evil/app.apk'), 3,
          signingPublicKeyB64: testPubKey);
      expect(m.decision, UpdateDecision.unverifiable);
    });

    test('the wrong public key rejects a genuine signature → unverifiable', () {
      final wrongKey = base64.encode(List<int>.filled(32, 7));
      final m = evaluateUpdateManifest(signed(), 3, signingPublicKeyB64: wrongKey);
      expect(m.decision, UpdateDecision.unverifiable);
    });

    test('no signing key configured → signature not required (backward compat)', () {
      final m = evaluateUpdateManifest(signed(sig: null), 3);
      expect(m.decision, UpdateDecision.install);
    });

    test('verifyManifestSignature: valid true; malformed/short sig false, never throws', () {
      expect(verifyManifestSignature(signed(), testPubKey), isTrue);
      expect(verifyManifestSignature(signed(sig: 'not valid base64 !!'), testPubKey), isFalse);
      expect(verifyManifestSignature(signed(sig: base64.encode(List<int>.filled(10, 0))), testPubKey),
          isFalse);
      expect(verifyManifestSignature(signed(sig: null), testPubKey), isFalse);
    });

    test('canonicalManifestPayload is the exact newline-joined field order', () {
      expect(canonicalManifestPayload(signed()),
          '4\n1.0.2\nhttps://github.com/x/app.apk\n$sha\n100');
    });
  });
}
