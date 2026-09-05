import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class RouteResult {
  const RouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;

  String get etaLabel {
    final total = durationSeconds.round();
    final minutes = (total / 60).floor();
    if (minutes < 1) return '< 1 min';
    if (minutes < 60) return '$minutes min';
    final hours = minutes ~/ 60;
    final remain = minutes % 60;
    return remain == 0 ? '${hours}h' : '${hours}h ${remain}m';
  }

  String get distanceLabel {
    if (distanceMeters < 1000) {
      return '${distanceMeters.round()} m';
    }
    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }
}

class MultiRouteResult {
  const MultiRouteResult({
    required this.stopOrder,
    required this.points,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.legDistanceMeters,
    required this.legDurationSeconds,
  });

  final List<int> stopOrder;
  final List<LatLng> points;
  final double totalDistanceMeters;
  final double totalDurationSeconds;
  final List<double> legDistanceMeters;
  final List<double> legDurationSeconds;
}

class RoutingException implements Exception {
  const RoutingException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum OsrmOverview { simplified, full, none }

class OsrmRoutingService {
  OsrmRoutingService({
    http.Client? client,
    this.baseUrl = 'https://router.project-osrm.org',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Map<String, dynamic> _cache = {};
  static const int _cacheLimit = 80;
  static const Duration _requestTimeout = Duration(seconds: 15);

  Future<RouteResult> route(
    LatLng origin,
    LatLng destination, {
    bool useCache = true,
  }) async {
    final key = 'r|${_coordKey(origin)}|${_coordKey(destination)}';
    if (useCache && _cache.containsKey(key)) {
      return _cache[key] as RouteResult;
    }

    final coordinates = '${_toOsrm(origin)};${_toOsrm(destination)}';
    final params = <String, String>{
      'overview': 'simplified',
      'geometries': 'geojson',
      'steps': 'false',
      'annotations': 'false',
    };

    final uri = Uri.parse(
      '$baseUrl/route/v1/driving/$coordinates',
    ).replace(queryParameters: params);

    final result = await _requestRoute(uri, expectedLegs: 1);
    _cachePut(key, result);
    return result;
  }

  Future<MultiRouteResult> multiStopRoute(
    List<LatLng> stops, {
    List<int>? preferredOrder,
  }) async {
    if (stops.length < 2) {
      throw const RoutingException('At least two stops are required.');
    }

    List<int> order;
    if (preferredOrder != null) {
      order = preferredOrder.toList();
    } else if (stops.length == 2) {
      order = const [0, 1];
    } else {
      order = List<int>.generate(stops.length, (i) => i);
    }

    final ordered = order.map((i) => stops[i]).toList(growable: false);
    final coords = ordered.map(_toOsrm).join(';');
    final params = <String, String>{
      'overview': 'full',
      'geometries': 'geojson',
      'steps': 'false',
    };
    final uri = Uri.parse(
      '$baseUrl/route/v1/driving/$coords',
    ).replace(queryParameters: params);

    final response = await _get(uri);
    final payload = _parsePayload(response);
    final routes = payload['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) {
      throw const RoutingException('No route found for provided stops.');
    }
    final first = routes.first as Map<String, dynamic>;
    final legs = first['legs'] as List<dynamic>? ?? const [];
    if (legs.isEmpty) {
      throw const RoutingException('Route has no legs.');
    }

    final geometry = _parseGeometry(first['geometry']);
    final legDistances = <double>[];
    final legDurations = <double>[];
    double totalDist = 0;
    double totalDur = 0;
    for (final leg in legs) {
      final l = leg as Map<String, dynamic>;
      final d = (l['distance'] as num?)?.toDouble() ?? 0;
      final t = (l['duration'] as num?)?.toDouble() ?? 0;
      legDistances.add(d);
      legDurations.add(t);
      totalDist += d;
      totalDur += t;
    }

    return MultiRouteResult(
      stopOrder: order,
      points: geometry,
      totalDistanceMeters: totalDist,
      totalDurationSeconds: totalDur,
      legDistanceMeters: legDistances,
      legDurationSeconds: legDurations,
    );
  }

  Future<RouteResult> _requestRoute(
    Uri uri, {
    required int expectedLegs,
  }) async {
    final response = await _get(uri);
    final payload = _parsePayload(response);
    final routes = payload['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) {
      throw const RoutingException('No route found between those locations.');
    }
    final first = routes.first as Map<String, dynamic>;
    final legs = first['legs'] as List<dynamic>? ?? const [];
    if (legs.length < expectedLegs) {
      throw const RoutingException('Route response is missing legs.');
    }
    double distance = 0;
    double duration = 0;
    for (final leg in legs) {
      final l = leg as Map<String, dynamic>;
      distance += (l['distance'] as num?)?.toDouble() ?? 0;
      duration += (l['duration'] as num?)?.toDouble() ?? 0;
    }
    final points = _parseGeometry(first['geometry']);
    if (points.isEmpty) {
      throw const RoutingException('Route has no geometry.');
    }
    return RouteResult(
      points: points,
      distanceMeters: distance,
      durationSeconds: duration,
    );
  }

  Future<http.Response> _get(Uri uri) async {
    try {
      return await _client
          .get(
            uri,
            headers: const {
              'Accept': 'application/json',
              'User-Agent': 'InfraGo-Mobile/1.0 (BMIT2073 student project)',
            },
          )
          .timeout(_requestTimeout);
    } on RoutingException {
      rethrow;
    } catch (_) {
      throw const RoutingException(
        'Could not reach the routing service. Check your connection.',
      );
    }
  }

  Map<String, dynamic> _parsePayload(http.Response response) {
    if (response.statusCode != 200) {
      throw RoutingException(
        'Routing service returned an error (${response.statusCode}).',
      );
    }
    try {
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final code = payload['code'] as String?;
      if (code != 'Ok') {
        throw RoutingException(
          'Routing service rejected the request${code == null ? '' : ': $code'}.',
        );
      }
      return payload;
    } on RoutingException {
      rethrow;
    } catch (_) {
      throw const RoutingException(
        'The routing service returned an invalid response.',
      );
    }
  }

  List<LatLng> _parseGeometry(dynamic geometry) {
    if (geometry == null) return const [];
    if (geometry is Map<String, dynamic>) {
      final type = geometry['type'] as String?;
      if (type == 'LineString') {
        final coords = geometry['coordinates'] as List<dynamic>? ?? const [];
        final out = <LatLng>[];
        for (final c in coords) {
          if (c is List && c.length >= 2) {
            out.add(LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
          }
        }
        return out;
      }
    }
    return const [];
  }

  void _cachePut(String key, RouteResult result) {
    if (_cache.length >= _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = result;
  }

  static String _toOsrm(LatLng p) =>
      '${p.longitude.toStringAsFixed(6)},${p.latitude.toStringAsFixed(6)}';

  static String _coordKey(LatLng p) =>
      '${p.latitude.toStringAsFixed(4)}_${p.longitude.toStringAsFixed(4)}';

  void close() => _client.close();
}

double bearingBetween(LatLng from, LatLng to) {
  final lat1 = from.latitudeInRad;
  final lat2 = to.latitudeInRad;
  final dLon = to.longitudeInRad - from.longitudeInRad;
  final y = math.sin(dLon) * math.cos(lat2);
  final x =
      math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  final brng = math.atan2(y, x);
  return (brng * 180 / math.pi + 360) % 360;
}

double directionDifferenceDegrees(double a, double b) {
  final diff = (a - b).abs();
  return diff > 180 ? 360 - diff : diff;
}

double haversineMeters(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = b.latitudeInRad - a.latitudeInRad;
  final dLon = b.longitudeInRad - a.longitudeInRad;
  final s1 = math.sin(dLat / 2);
  final s2 = math.sin(dLon / 2);
  final h =
      s1 * s1 + math.cos(a.latitudeInRad) * math.cos(b.latitudeInRad) * s2 * s2;
  return 2 * r * math.asin(math.sqrt(h));
}

// Peninsular Malaysia (West Malaysia / Semenanjung) bounding box.
// Covers the full peninsula plus a sensible coastal buffer; excludes East
// Malaysia (Sarawak / Sabah) which is on Borneo and would make no sense for
// a local urban ride-hail trip.
const double kPeninsularMyMinLat = 0.8;
const double kPeninsularMyMaxLat = 7.6;
const double kPeninsularMyMinLng = 99.5;
const double kPeninsularMyMaxLng = 105.0;

/// Photon bbox in the required order: minLon,minLat,maxLon,maxLat.
/// Must match the kPeninsularMyMin/Max values above; written as a literal
/// because const contexts cannot invoke toStringAsFixed().
const String kPeninsularMyPhotonBbox = '99.50,0.80,105.00,7.60';

/// Returns true when [point] lies within the Peninsular Malaysia rectangle.
bool isInsidePeninsularMalaysia(LatLng point) {
  final lat = point.latitude;
  final lng = point.longitude;
  return lat >= kPeninsularMyMinLat &&
      lat <= kPeninsularMyMaxLat &&
      lng >= kPeninsularMyMinLng &&
      lng <= kPeninsularMyMaxLng;
}

/// Human-readable label for the allowed ride area, reused in error messages.
const String kPeninsularMyAreaLabel = 'Peninsular Malaysia';

/// Maximum road distance for a single booking; above this a ride-hail trip
/// is not economically reasonable and the rider must use intercity transport.
const double kMaximumRideDistanceMeters = 200 * 1000; // 200 km

/// Error message shown when a pickup/destination is outside the allowed area.
const String kErrorOutsideMyRegion =
    'Pickup and destination can only be within $kPeninsularMyAreaLabel.';

/// Error message shown when computed route distance exceeds the cap.
String kErrorRideTooFar(double distanceMeters) {
  final km = (distanceMeters / 1000).toStringAsFixed(0);
  final capKm = (kMaximumRideDistanceMeters / 1000).toStringAsFixed(0);
  return 'This ride is $km km, which exceeds the $capKm km limit. Try a shorter trip or split the journey.';
}
