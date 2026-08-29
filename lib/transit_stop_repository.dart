import 'dart:async';

import 'package:latlong2/latlong.dart';

import 'osrm_routing_service.dart';

abstract class TransitStop {
  String get id;
  String get name;
  String? get code;
  String? get route;
  LatLng get location;
  String? get source;
  DateTime? get lastUpdated;

  bool get isStale {
    final u = lastUpdated;
    if (u == null) return true;
    return DateTime.now().difference(u) > const Duration(hours: 6);
  }
}

class TransitStopValue implements TransitStop {
  const TransitStopValue({
    required this.id,
    required this.name,
    required this.location,
    this.code,
    this.route,
    this.source,
    this.lastUpdated,
  });

  @override
  final String id;
  @override
  final String name;
  @override
  final String? code;
  @override
  final String? route;
  @override
  final LatLng location;
  @override
  final String? source;
  @override
  final DateTime? lastUpdated;

  @override
  bool get isStale {
    final u = lastUpdated;
    if (u == null) return true;
    return DateTime.now().difference(u) > const Duration(hours: 6);
  }
}

class NearbyTransitStop {
  const NearbyTransitStop({required this.stop, required this.distanceMeters});

  final TransitStop stop;
  final double distanceMeters;

  String get distanceLabel => distanceMeters < 1000
      ? '${distanceMeters.round()} m'
      : '${(distanceMeters / 1000).toStringAsFixed(1)} km';
}

class TransitRepositoryException implements Exception {
  const TransitRepositoryException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class TransitStopRepository {
  Future<List<NearbyTransitStop>> nearest(
    LatLng center, {
    int limit = 5,
    double radiusMeters = 2000,
  });
}

typedef TransitStopRowsLoader = Future<List<Map<String, dynamic>>> Function();

class DatabaseTransitStopRepository implements TransitStopRepository {
  DatabaseTransitStopRepository(this.loadRows);

  final TransitStopRowsLoader loadRows;

  @override
  Future<List<NearbyTransitStop>> nearest(
    LatLng center, {
    int limit = 5,
    double radiusMeters = 2000,
  }) async {
    List<Map<String, dynamic>> rows;
    try {
      rows = await loadRows();
    } catch (error) {
      throw TransitRepositoryException(
        'Official GTFS stop data is unavailable: $error',
      );
    }

    final nearby = <NearbyTransitStop>[];
    for (final row in rows) {
      final latitude = (row['latitude'] as num?)?.toDouble();
      final longitude = (row['longitude'] as num?)?.toDouble();
      final id = row['stop_id']?.toString();
      final name = row['stop_name']?.toString();
      if (latitude == null || longitude == null || id == null || name == null) {
        continue;
      }
      final stop = TransitStopValue(
        id: id,
        name: name,
        code: row['stop_code']?.toString(),
        route: row['route_name']?.toString(),
        location: LatLng(latitude, longitude),
        source: row['source']?.toString() ?? 'data.gov.my GTFS Static',
        lastUpdated: DateTime.tryParse(row['updated_at']?.toString() ?? ''),
      );
      final distance = haversineMeters(center, stop.location);
      if (distance <= radiusMeters) {
        nearby.add(NearbyTransitStop(stop: stop, distanceMeters: distance));
      }
    }
    nearby.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return nearby.take(limit).toList(growable: false);
  }
}

class FakeTransitStopRepository implements TransitStopRepository {
  FakeTransitStopRepository(this._stops, {this.delay = Duration.zero});

  final List<TransitStop> _stops;
  final Duration delay;

  @override
  Future<List<NearbyTransitStop>> nearest(
    LatLng center, {
    int limit = 5,
    double radiusMeters = 2000,
  }) async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final out = <NearbyTransitStop>[];
    for (final s in _stops) {
      final d = haversineMeters(center, s.location);
      if (d <= radiusMeters) {
        out.add(NearbyTransitStop(stop: s, distanceMeters: d));
      }
    }
    out.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return out.take(limit).toList(growable: false);
  }
}
