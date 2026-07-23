import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'diag.dart';

/// The dead-zone half of Forest's brain. No LLM, no network — a small intent
/// matcher over the driver's everyday phrases, a cached copy of their loads,
/// and a store-and-forward queue that drains the moment coverage returns.
/// Anything it can't handle becomes a queued note for the online Forest, so a
/// driver is never told "try again later" with nothing saved.
class OfflineBrain {
  static const _queueKey = 'offline_voice_queue';
  static const _loadsKey = 'offline_cached_loads';

  /// Refresh the load cache whenever the app has loads in hand (called from
  /// the online path — this is what "what's my next stop" reads in a canyon).
  static Future<void> cacheLoads(List<DriverLoad> loads) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
        _loadsKey,
        jsonEncode(loads
            .map((l) => {
                  'id': l.id,
                  'load_number': l.loadNumber,
                  'status': l.status,
                  'pickup': l.pickup,
                  'delivery': l.delivery,
                  'customer': l.customerName,
                })
            .toList()));
  }

  static Future<List<Map<String, dynamic>>> _cachedLoads() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_loadsKey);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _enqueue(Map<String, dynamic> item) async {
    final sp = await SharedPreferences.getInstance();
    final list = _decodeQueue(sp.getString(_queueKey));
    list.add({...item, 'ts': DateTime.now().toIso8601String()});
    await sp.setString(_queueKey, jsonEncode(list));
  }

  static List<Map<String, dynamic>> _decodeQueue(String? raw) {
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<int> pendingCount() async {
    final sp = await SharedPreferences.getInstance();
    return _decodeQueue(sp.getString(_queueKey)).length;
  }

  /// Handle one utterance offline. Returns the sentence Forest should SAY.
  static Future<String> handle(String text) async {
    final t = text.toLowerCase().trim();
    if (t.isEmpty) return "I didn't catch that.";

    // status intents — the words drivers actually use on the radio
    final statusMap = <RegExp, (String, String)>{
      RegExp(r'\b(arrived|at the (shipper|receiver|dock)|checked? in)\b'):
          ('arrived', 'arrived'),
      RegExp(r'\b(loaded|picked up|got the load)\b'): ('loaded', 'loaded'),
      RegExp(r'\b(empty|delivered|dropped|unloaded|done with this one)\b'):
          ('delivered', 'delivered'),
      RegExp(r'\b(rolling|in transit|heading out|on the road)\b'):
          ('in_transit', 'rolling'),
    };
    for (final e in statusMap.entries) {
      if (e.key.hasMatch(t)) {
        final loads = await _cachedLoads();
        final active = loads.where((l) =>
            l['status'] != 'delivered' && l['status'] != 'cancelled').toList();
        if (active.isEmpty) {
          await _enqueue({'type': 'note', 'text': text});
          return 'No coverage out here and I have no cached load to update — '
              'I saved your words and will sort it out when we reconnect.';
        }
        final target = active.first;
        await _enqueue({
          'type': 'status',
          'load_id': target['id'],
          'status': e.value.$1,
        });
        return 'Got it — marking load ${target['load_number']} ${e.value.$2}. '
            "We're in a dead zone, so I'll send it the moment we have signal.";
      }
    }

    // where am I going
    if (RegExp(r"\b(next stop|where.*(going|headed)|what.*deliver)").hasMatch(t)) {
      final loads = await _cachedLoads();
      final active = loads.where((l) =>
          l['status'] != 'delivered' && l['status'] != 'cancelled').toList();
      if (active.isEmpty) {
        return "I don't have a cached load right now. I'll refresh when we're "
            'back in coverage.';
      }
      final l = active.first;
      return 'Load ${l['load_number']}'
          '${l['customer'] != null ? ' for ${l['customer']}' : ''}: '
          'delivering to ${l['delivery']}.';
    }

    // queued-work status
    if (RegExp(r'\b(anything (pending|queued)|what.*waiting)\b').hasMatch(t)) {
      final n = await pendingCount();
      return n == 0
          ? 'Nothing queued — all caught up.'
          : '$n update${n == 1 ? '' : 's'} waiting for signal. '
              "I'll push them automatically.";
    }

    // everything else: keep the words, promise the follow-up
    await _enqueue({'type': 'note', 'text': text});
    return "We're out of coverage so I can't work on that right now — "
        "I wrote it down word for word and I'll handle it as soon as "
        'we reconnect.';
  }

  /// Push everything queued. Call whenever connectivity returns. Items that
  /// fail stay queued; notes go to the online Forest as plain messages so the
  /// full brain (and its audit trail) deals with them properly.
  static Future<int> drain(CompanionApi api) async {
    final sp = await SharedPreferences.getInstance();
    final list = _decodeQueue(sp.getString(_queueKey));
    if (list.isEmpty) return 0;
    final remaining = <Map<String, dynamic>>[];
    var sent = 0;
    for (final item in list) {
      try {
        switch (item['type']) {
          case 'status':
            await api.changeStatus(item['load_id'] as int, item['status'] as String);
            sent++;
          case 'note':
            await api.truxSend(
                message: '[voice note captured offline at ${item['ts']}] '
                    '${item['text']}');
            sent++;
          default:
            sent++; // unknown legacy item — drop rather than wedge the queue
        }
      } catch (e) {
        Diag.log('offline-brain: drain item failed, keeping: $e');
        remaining.add(item);
      }
    }
    await sp.setString(_queueKey, jsonEncode(remaining));
    return sent;
  }
}
