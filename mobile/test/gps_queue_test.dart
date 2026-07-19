import 'package:flutter_test/flutter_test.dart';

import 'package:truxon_companion/services/tracking_service.dart';

/// Queue semantics that protect GPS fix data in the background isolate:
/// bounded growth, batched uploads, and remove-only-on-confirmed-upload.
void main() {
  Map<String, dynamic> fix(int i) => {'lat': i.toDouble(), 'lng': 0.0};

  group('GpsQueue', () {
    test('caps at 5000, dropping the oldest fixes', () {
      final q = GpsQueue();
      for (var i = 0; i < GpsQueue.cap + 5; i++) {
        q.add(fix(i));
      }
      expect(q.length, GpsQueue.cap);
      // The 5 oldest were dropped; the newest survived.
      expect(q.items.first['lat'], 5.0);
      expect(q.items.last['lat'], (GpsQueue.cap + 4).toDouble());
    });

    test('nextBatch returns the oldest 100 in insertion order, non-destructively', () {
      final q = GpsQueue();
      for (var i = 0; i < 250; i++) {
        q.add(fix(i));
      }
      final batch = q.nextBatch();
      expect(batch.length, GpsQueue.batchSize);
      expect(batch.first['lat'], 0.0);
      expect(batch.last['lat'], 99.0);
      // Peeking must not remove anything — only a confirmed upload does.
      expect(q.length, 250);
    });

    test('nextBatch on a short queue returns everything', () {
      final q = GpsQueue();
      for (var i = 0; i < 7; i++) {
        q.add(fix(i));
      }
      expect(q.nextBatch().length, 7);
    });

    test('markUploaded removes exactly the confirmed batch, keeping the rest in order', () {
      final q = GpsQueue();
      for (var i = 0; i < 250; i++) {
        q.add(fix(i));
      }
      q.markUploaded(q.nextBatch().length);
      expect(q.length, 150);
      expect(q.items.first['lat'], 100.0);
    });

    test('failed upload (no markUploaded) keeps every fix — 401 loses nothing', () {
      final q = GpsQueue();
      for (var i = 0; i < 150; i++) {
        q.add(fix(i));
      }
      final first = q.nextBatch();
      // Upload came back 401/403 or network died: nothing removed, and the
      // next attempt retries the exact same batch.
      expect(q.length, 150);
      expect(q.nextBatch(), first);
    });

    test('restore replaces contents from a persisted snapshot', () {
      final q = GpsQueue();
      q.add(fix(99));
      q.restore([fix(1), fix(2)]);
      expect(q.length, 2);
      expect(q.items.first['lat'], 1.0);
    });
  });

  group('AuthOutage', () {
    final t0 = DateTime.utc(2026, 1, 1, 12, 0);

    test('starts healthy: not failing, no warning due', () {
      final o = AuthOutage();
      expect(o.failing, isFalse);
      expect(o.warnDue(t0), isFalse);
    });

    test('warns only after 5 minutes of continuous auth failures', () {
      final o = AuthOutage();
      o.recordAuthFailure(t0);
      expect(o.failing, isTrue);
      expect(o.warnDue(t0.add(const Duration(minutes: 4))), isFalse);
      expect(o.warnDue(t0.add(const Duration(minutes: 5))), isTrue);
    });

    test('repeated failures do not reset the outage clock', () {
      final o = AuthOutage();
      o.recordAuthFailure(t0);
      o.recordAuthFailure(t0.add(const Duration(minutes: 4)));
      // Still measured from the FIRST failure.
      expect(o.warnDue(t0.add(const Duration(minutes: 5))), isTrue);
    });

    test('one successful upload clears the outage and the warning', () {
      final o = AuthOutage();
      o.recordAuthFailure(t0);
      o.recordSuccess();
      expect(o.failing, isFalse);
      expect(o.warnDue(t0.add(const Duration(hours: 1))), isFalse);
    });
  });
}
