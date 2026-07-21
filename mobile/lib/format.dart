/// Pure display formatters shared by the role home screens (dispatch /
/// collections / command). Deliberately free of Flutter and i18n so they are
/// unit-tested directly and can't drift apart between screens.
library;

/// Whole-dollar, thousands-separated: `1234 → "$1,234"`. Null-safe (→ "$0").
/// Negatives keep the sign OUTSIDE the digits (`-1234 → "-$1,234"`) — the old
/// per-screen copies counted the leading "-" as a digit and produced
/// "$-,123,456", so a credit or adjustment rendered as garbage.
String money(num? v) {
  final n = (v ?? 0).round();
  final neg = n < 0;
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '${neg ? '-' : ''}\$$b';
}

/// mph from a GPS speed in metres/second, rounded. Null → 0.
int mphFromMps(num? mps) => ((mps ?? 0) * 2.23694).round();

/// A truck reads as "moving" only above a small threshold, so GPS jitter while
/// parked doesn't flicker a stopped truck as rolling.
bool isMoving(int mph) => mph > 3;

/// Compact "time since": "—" when unknown/unparseable, [justNow] under a
/// minute (and for any future/skewed timestamp), then "5m" up to an hour, then
/// "2h". [now] is injected so the result is deterministic under test.
String relativeAgo(String? iso, {required DateTime now, required String justNow}) {
  if (iso == null) return '—';
  final t = DateTime.tryParse(iso);
  if (t == null) return '—';
  final m = now.toUtc().difference(t.toUtc()).inMinutes;
  if (m < 1) return justNow;
  if (m < 60) return '${m}m';
  return '${(m / 60).floor()}h';
}
