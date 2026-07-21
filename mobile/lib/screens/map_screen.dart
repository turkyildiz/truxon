import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../i18n.dart';
import '../services/api.dart';
import '../services/diag.dart';

/// TABLET DAY — map v1: the truck, the next stop, and the route between.
/// Tiles from OpenStreetMap. Routing comes from a self-hosted Valhalla with
/// a real TRUCK costing profile (13'6" van height, 80k lbs) the moment
/// AppConfig.valhallaUrl is configured — until then the map shows a straight
/// bearing line, clearly labeled as not a road route. No deep links to side
/// apps; the one-app rule holds.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.load});
  final DriverLoad load;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  LatLng? _me;
  List<LatLng> _route = [];
  String? _routeSummary;
  bool _routed = false; // true when Valhalla produced a real truck route

  LatLng? get _target {
    final r = widget.load.raw;
    // in_transit → head to delivery; otherwise the pickup
    final toDelivery = widget.load.status == 'in_transit';
    final lat = r[toDelivery ? 'delivery_lat' : 'pickup_lat'] as num?;
    final lon = r[toDelivery ? 'delivery_lon' : 'pickup_lon'] as num?;
    if (lat == null || lon == null) return null;
    return LatLng(lat.toDouble(), lon.toDouble());
  }

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() => _me = LatLng(pos.latitude, pos.longitude));
      await _routeTo();
    } catch (e) {
      Diag.log('map: locate failed: $e');
    }
  }

  Future<void> _routeTo() async {
    final me = _me;
    final target = _target;
    if (me == null || target == null) return;
    if (AppConfig.valhallaUrl.isEmpty) {
      setState(() {
        _route = [me, target];
        _routed = false;
      });
      return;
    }
    try {
      final body = jsonEncode({
        'locations': [
          {'lat': me.latitude, 'lon': me.longitude},
          {'lat': target.latitude, 'lon': target.longitude},
        ],
        'costing': 'truck',
        'costing_options': {
          'truck': {'height': 4.11, 'width': 2.6, 'length': 21.0, 'weight': 36.28}
        },
        'units': 'miles',
      });
      final res = await http
          .post(Uri.parse('${AppConfig.valhallaUrl}/route'), body: body)
          .timeout(const Duration(seconds: 12));
      final trip = (jsonDecode(res.body) as Map)['trip'] as Map;
      final leg = (trip['legs'] as List).first as Map;
      final pts = _decodePolyline6(leg['shape'] as String);
      final summary = trip['summary'] as Map;
      if (!mounted) return;
      setState(() {
        _route = pts;
        _routed = true;
        _routeSummary =
            '${(summary['length'] as num).toStringAsFixed(0)} mi · ${((summary['time'] as num) / 3600).toStringAsFixed(1)} h';
      });
    } catch (e) {
      Diag.log('map: valhalla route failed, straight line: $e');
      if (mounted) {
        setState(() {
          _route = [me, target];
          _routed = false;
        });
      }
    }
  }

  /// Valhalla emits polyline6.
  static List<LatLng> _decodePolyline6(String encoded) {
    final pts = <LatLng>[];
    int index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      for (final isLng in [false, true]) {
        int result = 0, shift = 0, b;
        do {
          b = encoded.codeUnitAt(index++) - 63;
          result |= (b & 0x1f) << shift;
          shift += 5;
        } while (b >= 0x20);
        final delta = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
        if (isLng) {
          lng += delta;
        } else {
          lat += delta;
        }
      }
      pts.add(LatLng(lat / 1e6, lng / 1e6));
    }
    return pts;
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    final center = _me ?? target ?? const LatLng(39.5, -84.0);
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.load.loadNumber} — '
            '${widget.load.status == 'in_transit' ? tr('mapToDelivery') : tr('mapToPickup')}'),
      ),
      body: target == null
          ? Center(child: Text(tr('mapNoCoords')))
          : Column(
              children: [
                if (_routeSummary != null || !_routed)
                  Container(
                    width: double.infinity,
                    color: _routed ? Colors.green.withValues(alpha: 0.12) : Colors.amber.withValues(alpha: 0.15),
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _routed ? '🚛 $_routeSummary' : tr('mapStraightLine'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                Expanded(
                  child: FlutterMap(
                    options: MapOptions(initialCenter: center, initialZoom: 8),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.truxon.companion',
                      ),
                      if (_route.length >= 2)
                        PolylineLayer(polylines: [
                          Polyline(
                            points: _route,
                            strokeWidth: 4,
                            color: _routed ? Colors.indigo : Colors.grey,
                          ),
                        ]),
                      MarkerLayer(markers: [
                        if (_me != null)
                          Marker(
                            point: _me!,
                            width: 36,
                            height: 36,
                            child: const Icon(Icons.local_shipping, color: Colors.indigo, size: 32),
                          ),
                        Marker(
                          point: target,
                          width: 36,
                          height: 36,
                          child: const Icon(Icons.place, color: Colors.red, size: 34),
                        ),
                      ]),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
