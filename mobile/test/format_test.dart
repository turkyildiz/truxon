import 'package:flutter_test/flutter_test.dart';
import 'package:truxon_companion/format.dart';

void main() {
  group('money', () {
    test('null and zero', () {
      expect(money(null), '\$0');
      expect(money(0), '\$0');
    });
    test('rounds to whole dollars', () {
      expect(money(1234.56), '\$1,235');
      expect(money(1234.4), '\$1,234');
    });
    test('thousands separators at every boundary', () {
      expect(money(999), '\$999');
      expect(money(1000), '\$1,000');
      expect(money(12345), '\$12,345');
      expect(money(123456), '\$123,456');
      expect(money(1234567), '\$1,234,567');
    });
    test('negatives keep the sign outside the digits (the old bug)', () {
      // Old per-screen copy produced "$-,123,456"; the sign must lead.
      expect(money(-1234), '-\$1,234');
      expect(money(-123456), '-\$123,456');
      expect(money(-50), '-\$50');
    });
  });

  group('mphFromMps / isMoving', () {
    test('converts m/s to mph', () {
      expect(mphFromMps(null), 0);
      expect(mphFromMps(0), 0);
      expect(mphFromMps(29.06), 65); // ~65 mph highway
    });
    test('moving threshold ignores parked jitter', () {
      expect(isMoving(0), isFalse);
      expect(isMoving(3), isFalse); // at threshold → still stopped
      expect(isMoving(4), isTrue);
      expect(isMoving(65), isTrue);
    });
  });

  group('relativeAgo', () {
    final now = DateTime.utc(2026, 7, 21, 12, 0, 0);
    String ago(String? iso) => relativeAgo(iso, now: now, justNow: 'just now');

    test('null / unparseable → dash', () {
      expect(ago(null), '—');
      expect(ago('not-a-date'), '—');
    });
    test('under a minute → just now', () {
      expect(ago('2026-07-21T11:59:30Z'), 'just now');
    });
    test('minutes then hours', () {
      expect(ago('2026-07-21T11:55:00Z'), '5m');
      expect(ago('2026-07-21T11:01:00Z'), '59m');
      expect(ago('2026-07-21T10:00:00Z'), '2h');
      expect(ago('2026-07-20T12:00:00Z'), '24h');
    });
    test('future timestamp (clock skew) → just now, never negative', () {
      expect(ago('2026-07-21T12:05:00Z'), 'just now');
    });
  });
}
