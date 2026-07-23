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
  /// R9 #139/#140: more intents (pickup, load number, breakdown, detention
  /// stamp) and Spanish coverage — a Spanish phrase gets a Spanish answer.
  static Future<String> handle(String text) async {
    final t = text.toLowerCase().trim();
    if (t.isEmpty) return "I didn't catch that.";

    // R9 #139: breakdown + detention run BEFORE the status intents — "still
    // waiting at the dock" must never read as "arrived at the dock".
    // Spanish patterns avoid a trailing \b: Dart's ASCII word-boundary fails
    // right after an accented character (entregué + \b never matches).
    final brokeEs =
        RegExp(r'\b(se (descompuso|da[ñn][oó])|aver[ií]a|llanta (ponchada|baja))')
            .hasMatch(t);
    if (RegExp(r'\b(broke down|breakdown|flat tire|blew a tire|engine (died|trouble)|won.?t start)\b')
            .hasMatch(t) ||
        brokeEs) {
      await _enqueue({'type': 'note', 'text': '[BREAKDOWN reported offline] $text'});
      return brokeEs
          ? 'Anotado. Sin señal no puedo avisar a la oficina todavía — se envía '
              'solo cuando vuelva la señal. Si es urgente usa el botón de avería, '
              'y si alguien está herido llama al 911.'
          : "Logged it. No signal, so the office can't hear us yet — it goes out "
              'the moment coverage returns. If it can\'t wait, use the breakdown '
              'button; if anyone is hurt, call 911.';
    }

    final waitEs =
        RegExp(r'\b(sigo esperando|llevo .* esperando|detenci[oó]n)').hasMatch(t);
    if (RegExp(r"\b(still (waiting|sitting)|been (waiting|sitting|here))\b|\bdetention\b")
            .hasMatch(t) ||
        waitEs) {
      await _enqueue({'type': 'note', 'text': '[DETENTION note] $text'});
      return waitEs
          ? 'Apuntado con hora — eso sirve como evidencia de detención. '
              'Lo mando en cuanto haya señal.'
          : 'Stamped it with the time — that\'s detention evidence. '
              "I'll send it up the moment we have signal.";
    }

    // status intents — the words drivers actually use on the radio.
    // (status, spoken-en, spoken-es); Spanish patterns sit beside English so
    // one pass decides both the intent and the reply language.
    final statusIntents = <(RegExp, RegExp, String, String, String)>[
      (
        RegExp(r'\b(arrived|at the (shipper|receiver|dock)|checked? in)\b'),
        RegExp(r'\b(llegu[eé]|llegamos|estoy en el (muelle|cliente|shipper))'),
        'arrived', 'arrived', 'llegado'
      ),
      (
        RegExp(r'\b(loaded|picked up|got the load)\b'),
        RegExp(r'\b(cargado|cargamos|ya cargu[eé]|recog[ií] la carga)'),
        'loaded', 'loaded', 'cargado'
      ),
      (
        RegExp(r'\b(empty|delivered|dropped|unloaded|done with this one)\b'),
        RegExp(r'\b(vac[ií]o|entregado|entregamos|ya entregu[eé]|descargado)'),
        'delivered', 'delivered', 'entregado'
      ),
      (
        RegExp(r'\b(rolling|in transit|heading out|on the road)\b'),
        RegExp(r'\b(rodando|en camino|en ruta|saliendo)\b'),
        'in_transit', 'rolling', 'en camino'
      ),
    ];
    for (final (en, es, status, spokenEn, spokenEs) in statusIntents) {
      final isEs = es.hasMatch(t);
      if (en.hasMatch(t) || isEs) {
        final loads = await _cachedLoads();
        final active = loads.where((l) =>
            l['status'] != 'delivered' && l['status'] != 'cancelled').toList();
        if (active.isEmpty) {
          await _enqueue({'type': 'note', 'text': text});
          return isEs
              ? 'No hay señal y no tengo una carga guardada para actualizar — '
                  'anoté tus palabras y lo resuelvo cuando volvamos a tener señal.'
              : 'No coverage out here and I have no cached load to update — '
                  'I saved your words and will sort it out when we reconnect.';
        }
        final target = active.first;
        await _enqueue({
          'type': 'status',
          'load_id': target['id'],
          'status': status,
        });
        return isEs
            ? 'Listo — marco la carga ${target['load_number']} como $spokenEs. '
                'Estamos sin señal, lo envío en cuanto vuelva.'
            : 'Got it — marking load ${target['load_number']} $spokenEn. '
                "We're in a dead zone, so I'll send it the moment we have signal.";
      }
    }

    // where am I going / delivery
    final askDeliverEs =
        RegExp(r'\b(a ?d[oó]nde voy|pr[oó]xima parada|d[oó]nde entrego)\b').hasMatch(t);
    if (RegExp(r"\b(next stop|where.*(going|headed)|what.*deliver)").hasMatch(t) ||
        askDeliverEs) {
      final l = await _activeLoad();
      if (l == null) {
        return askDeliverEs
            ? 'No tengo una carga guardada ahora. Actualizo cuando haya señal.'
            : "I don't have a cached load right now. I'll refresh when we're "
                'back in coverage.';
      }
      return askDeliverEs
          ? 'Carga ${l['load_number']}'
              '${l['customer'] != null ? ' para ${l['customer']}' : ''}: '
              'entrega en ${l['delivery']}.'
          : 'Load ${l['load_number']}'
              '${l['customer'] != null ? ' for ${l['customer']}' : ''}: '
              'delivering to ${l['delivery']}.';
    }

    // R9 #139: where do I pick up
    final askPickupEs = RegExp(r'\b(d[oó]nde (recojo|cargo))\b').hasMatch(t);
    if (RegExp(r"\b(where.*pick ?up|pick ?up address|where('s| is) the shipper)\b")
            .hasMatch(t) ||
        askPickupEs) {
      final l = await _activeLoad();
      if (l == null) {
        return askPickupEs
            ? 'No tengo una carga guardada ahora.'
            : "I don't have a cached load right now.";
      }
      return askPickupEs
          ? 'Carga ${l['load_number']}: recoge en ${l['pickup']}.'
          : 'Load ${l['load_number']}: pick up at ${l['pickup']}.';
    }

    // R9 #139: load / confirmation number for the guard shack
    final askNumberEs = RegExp(r'\bn[uú]mero de (carga|confirmaci[oó]n)\b').hasMatch(t);
    if (RegExp(r'\b(load (number|#)|confirmation number|reference number)\b')
            .hasMatch(t) ||
        askNumberEs) {
      final l = await _activeLoad();
      if (l == null) {
        return askNumberEs
            ? 'No tengo una carga guardada ahora.'
            : "I don't have a cached load right now.";
      }
      return askNumberEs
          ? 'El número de carga es ${l['load_number']}.'
          : 'Your load number is ${l['load_number']}.';
    }

    // queued-work status
    final pendingEs = RegExp(r'\b(algo pendiente|qu[eé] (est[aá]|hay) (esperando|pendiente))')
        .hasMatch(t);
    if (RegExp(r'\b(anything (pending|queued)|what.*waiting)\b').hasMatch(t) ||
        pendingEs) {
      final n = await pendingCount();
      if (pendingEs) {
        return n == 0
            ? 'Nada pendiente — todo al día.'
            : '$n actualización${n == 1 ? '' : 'es'} esperando señal. '
                'Las envío automáticamente.';
      }
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

  static Future<Map<String, dynamic>?> _activeLoad() async {
    final loads = await _cachedLoads();
    final active = loads.where((l) =>
        l['status'] != 'delivered' && l['status'] != 'cancelled').toList();
    return active.isEmpty ? null : active.first;
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
