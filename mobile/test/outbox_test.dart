import 'package:flutter_test/flutter_test.dart';

import 'package:truxon_companion/services/api.dart';

/// Offline status outbox: encode/decode roundtrips and replay ordering —
/// status changes must reach the server oldest-first, and failures must stay
/// queued in their original order.
void main() {
  Map<String, dynamic> item(int id, String status) =>
      {'load_id': id, 'status': status};

  group('OfflineOutbox encode/decode', () {
    test('decode of null/empty returns an empty list', () {
      expect(OfflineOutbox.decode(null), isEmpty);
      expect(OfflineOutbox.decode(''), isEmpty);
    });

    test('roundtrip preserves items and order', () {
      final items = [item(1, 'in_transit'), item(2, 'delivered')];
      final out = OfflineOutbox.decode(OfflineOutbox.encode(items));
      expect(out, items);
    });
  });

  group('OfflineOutbox.replay', () {
    test('sends oldest-first and empties the outbox when all succeed', () async {
      final items = [item(1, 'in_transit'), item(2, 'delivered'), item(3, 'in_transit')];
      final sent = <int>[];
      final remaining = await OfflineOutbox.replay(items, (it) async {
        sent.add(it['load_id'] as int);
      });
      expect(sent, [1, 2, 3]); // FIFO — a delivered can't overtake its start.
      expect(remaining, isEmpty);
    });

    test('a failure keeps only that item, and later items are still attempted', () async {
      final items = [item(1, 'a'), item(2, 'b'), item(3, 'c')];
      final sent = <int>[];
      final remaining = await OfflineOutbox.replay(items, (it) async {
        final id = it['load_id'] as int;
        if (id == 2) throw Exception('offline');
        sent.add(id);
      });
      expect(sent, [1, 3]);
      expect(remaining, [item(2, 'b')]);
    });

    test('total failure keeps everything in original order', () async {
      final items = [item(1, 'a'), item(2, 'b'), item(3, 'c')];
      final remaining =
          await OfflineOutbox.replay(items, (_) async => throw Exception('offline'));
      expect(remaining, items);
    });
  });
}
