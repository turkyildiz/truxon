import 'package:flutter_test/flutter_test.dart';
import 'package:truxon_companion/services/forest_copilot.dart';

void main() {
  group('distanceKm', () {
    test('same point is zero', () {
      expect(ForestCopilot.distanceKm(41.88, -87.63, 41.88, -87.63), closeTo(0, 0.001));
    });
    test('Chicago→Columbus ~ 460 km', () {
      final d = ForestCopilot.distanceKm(41.88, -87.63, 39.96, -83.00);
      expect(d, closeTo(460, 40));
    });
  });

  group('decide — weather', () {
    test('new alert produces a cue', () {
      final cues = ForestCopilot.decide(
        alerts: [
          {'alert_id': 'A1', 'event': 'Tornado Warning', 'headline': 'Take cover now'}
        ],
        said: {},
      );
      expect(cues.length, 1);
      expect(cues.first.key, 'wx:A1');
      expect(cues.first.text, contains('Tornado Warning'));
      expect(cues.first.text, contains('Take cover now'));
    });
    test('already-said alert is skipped', () {
      final cues = ForestCopilot.decide(
        alerts: [{'alert_id': 'A1', 'event': 'Ice Storm'}],
        said: {'wx:A1'},
      );
      expect(cues, isEmpty);
    });
    test('missing headline still speaks', () {
      final cues = ForestCopilot.decide(
        alerts: [{'alert_id': 'A2', 'event': 'Blizzard Warning'}],
        said: {},
      );
      expect(cues.single.text, contains('Blizzard Warning'));
    });
  });

  group('decide — DVIR nudge', () {
    test('rolling without a pre-trip fires once', () {
      final cues = ForestCopilot.decide(
        alerts: const [],
        said: {},
        speedMps: 12,
        dvirDoneToday: false,
        today: '2026-07-22',
      );
      expect(cues.single.key, 'dvir:2026-07-22');
      expect(cues.single.text.toLowerCase(), contains('pre-trip'));
    });
    test('already nudged today stays quiet', () {
      final cues = ForestCopilot.decide(
        alerts: const [],
        said: {'dvir:2026-07-22'},
        speedMps: 12,
        dvirDoneToday: false,
        today: '2026-07-22',
      );
      expect(cues, isEmpty);
    });
    test('parked, DVIR done, or unknown → no nudge', () {
      for (final args in [
        (speed: 0.0, done: false),  // not moving yet
        (speed: 12.0, done: true),  // inspection is in
      ]) {
        expect(
          ForestCopilot.decide(
            alerts: const [],
            said: {},
            speedMps: args.speed,
            dvirDoneToday: args.done,
            today: '2026-07-22',
          ),
          isEmpty,
        );
      }
      // unknown (query failed) must never nag
      expect(
        ForestCopilot.decide(alerts: const [], said: {}, speedMps: 12, today: '2026-07-22'),
        isEmpty,
      );
    });
  });

  group('decide — arrival', () {
    final del = {
      'id': 7, 'status': 'in_transit',
      'delivery_lat': 41.880, 'delivery_lon': -87.630,
      'pickup_lat': 40.0, 'pickup_lon': -80.0,
    };
    test('within radius of delivery announces once', () {
      final cues = ForestCopilot.decide(
        lat: 41.882, lon: -87.631, load: del, alerts: const [], said: {},
      );
      expect(cues.single.key, 'arrive:7:delivery');
      expect(cues.single.text.toLowerCase(), contains('delivery'));
      expect(cues.single.text.toLowerCase(), contains('detention'));
    });
    test('far from stop stays silent', () {
      final cues = ForestCopilot.decide(
        lat: 42.5, lon: -88.5, load: del, alerts: const [], said: {},
      );
      expect(cues, isEmpty);
    });
    test('assigned load targets the PICKUP, not delivery', () {
      final pick = {
        'id': 9, 'status': 'assigned',
        'pickup_lat': 41.880, 'pickup_lon': -87.630,
        'delivery_lat': 30.0, 'delivery_lon': -90.0,
      };
      final cues = ForestCopilot.decide(
        lat: 41.881, lon: -87.630, load: pick, alerts: const [], said: {},
      );
      expect(cues.single.key, 'arrive:9:pickup');
    });
    test('delivered load never announces arrival', () {
      final done = {...del, 'status': 'delivered'};
      final cues = ForestCopilot.decide(
        lat: 41.880, lon: -87.630, load: done, alerts: const [], said: {},
      );
      expect(cues, isEmpty);
    });
    test('already-arrived key is skipped', () {
      final cues = ForestCopilot.decide(
        lat: 41.880, lon: -87.630, load: del, alerts: const [], said: {'arrive:7:delivery'},
      );
      expect(cues, isEmpty);
    });
  });

  test('weather + arrival can both fire in one pass', () {
    final cues = ForestCopilot.decide(
      lat: 41.880, lon: -87.630,
      load: {'id': 3, 'status': 'in_transit', 'delivery_lat': 41.880, 'delivery_lon': -87.630},
      alerts: [{'alert_id': 'Z', 'event': 'Flash Flood'}],
      said: {},
    );
    expect(cues.map((c) => c.key).toSet(), {'wx:Z', 'arrive:3:delivery'});
  });
}
