import 'package:flutter_test/flutter_test.dart';
import 'package:truxon_companion/services/auth_refresher.dart';

void main() {
  group('needsRefresh', () {
    test('fresh token (beyond skew) does not refresh', () {
      expect(
          AuthRefresher.needsRefresh({'expires_at': 1000 + 3600}, 1000), false);
    });
    test('inside the skew window refreshes', () {
      expect(AuthRefresher.needsRefresh({'expires_at': 1000 + 300}, 1000), true);
    });
    test('already expired refreshes', () {
      expect(AuthRefresher.needsRefresh({'expires_at': 900}, 1000), true);
    });
    test('missing expires_at treated as expired', () {
      expect(AuthRefresher.needsRefresh({}, 1000), true);
    });
  });

  group('lockHeld', () {
    test('no lock', () {
      expect(AuthRefresher.lockHeld(null, 1000000), false);
      expect(AuthRefresher.lockHeld('', 1000000), false);
    });
    test('fresh lock held', () {
      expect(AuthRefresher.lockHeld('abc-1:995000', 1000000), true);
    });
    test('stale lock (crashed refresher) not held', () {
      expect(AuthRefresher.lockHeld('abc-1:900000', 1000000), false);
    });
    test('garbage lock not held', () {
      expect(AuthRefresher.lockHeld('garbage', 1000000), false);
      expect(AuthRefresher.lockHeld('a:b:c', 1000000), false);
    });
    test('nonce containing colons still parses the trailing millis', () {
      expect(AuthRefresher.lockHeld('1:2:3:995000', 1000000), true);
    });
  });

  group('mergeSession', () {
    final old = {
      'access_token': 'oldA',
      'refresh_token': 'oldR',
      'token_type': 'bearer',
      'expires_at': 500,
      'expires_in': 3600,
      'user': {'id': 'u1'},
      'provider_token': 'keepme',
    };

    test('rotates tokens and recomputes expiry, keeps unknown fields', () {
      final merged = AuthRefresher.mergeSession(
          old, {'access_token': 'newA', 'refresh_token': 'newR', 'expires_in': 3600}, 1000);
      expect(merged['access_token'], 'newA');
      expect(merged['refresh_token'], 'newR');
      expect(merged['expires_at'], 1000 + 3600);
      expect(merged['provider_token'], 'keepme'); // untouched
      expect(merged['user'], {'id': 'u1'}); // kept when response omits it
      expect(merged['token_type'], 'bearer');
    });

    test('server-provided expires_at wins over computed', () {
      final merged = AuthRefresher.mergeSession(
          old,
          {'access_token': 'a', 'refresh_token': 'r', 'expires_in': 3600, 'expires_at': 9999},
          1000);
      expect(merged['expires_at'], 9999);
    });

    test('response user replaces old user', () {
      final merged = AuthRefresher.mergeSession(
          old,
          {
            'access_token': 'a',
            'refresh_token': 'r',
            'expires_in': 60,
            'user': {'id': 'u1', 'email': 'x@y.z'}
          },
          1000);
      expect((merged['user'] as Map)['email'], 'x@y.z');
    });
  });
}
