import 'dart:async';

import 'package:latlong2/latlong.dart';

import 'package:infra_go/kueh/osrm_routing_service.dart';

class CoarseVehicle {
  const CoarseVehicle({
    required this.anonymisedId,
    required this.coarseLocation,
    required this.compatibleCategories,
    required this.seenAt,
  });

  final String anonymisedId;
  final LatLng coarseLocation;
  final Set<String> compatibleCategories;
  final DateTime seenAt;
}

class ExactDriver {
  const ExactDriver({
    required this.driverId,
    required this.vehiclePlate,
    required this.exactLocation,
    required this.heading,
    required this.seenAt,
  });

  final String driverId;
  final String vehiclePlate;
  final LatLng exactLocation;
  final double heading;
  final DateTime seenAt;
}

class VehiclePresenceException implements Exception {
  const VehiclePresenceException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef CoarsePresenceStreamFactory =
    Stream<List<Map<String, dynamic>>> Function(LatLng center);

typedef ExactPresenceStreamFactory =
    Stream<Map<String, dynamic>?> Function(String rideId);

class VehiclePresenceService {
  VehiclePresenceService({
    this.maxAge = const Duration(seconds: 60),
    this.maxVehicles = 20,
    this.coarseFactory,
    this.exactFactory,
    this.now,
  });

  final Duration maxAge;
  final int maxVehicles;
  final CoarsePresenceStreamFactory? coarseFactory;
  final ExactPresenceStreamFactory? exactFactory;
  final DateTime? now;

  List<CoarseVehicle> filterCoarse({
    required List<Map<String, dynamic>> raw,
    required LatLng center,
    required String category,
    required double radiusMeters,
  }) {
    final threshold = (now ?? DateTime.now()).subtract(maxAge);
    final out = <CoarseVehicle>[];
    for (final r in raw) {
      try {
        final seenAt =
            DateTime.tryParse(r['last_seen_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        if (seenAt.isBefore(threshold)) continue;
        if (r['is_online'] != true) continue;
        if (r['is_assigned'] == true) continue;
        final cats =
            (r['vehicle_categories'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toSet() ??
            const <String>{};
        if (!cats.contains(category)) continue;
        final lat = (r['coarse_lat'] as num?)?.toDouble();
        final lng = (r['coarse_lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        final loc = LatLng(lat, lng);
        if (haversineMeters(center, loc) > radiusMeters) continue;

        final anonymisedId = r['anonymised_id'] as String?;
        if (anonymisedId == null || anonymisedId.isEmpty) continue;
        out.add(
          CoarseVehicle(
            anonymisedId: anonymisedId,
            coarseLocation: loc,
            compatibleCategories: cats,
            seenAt: seenAt,
          ),
        );
      } catch (_) {
        continue;
      }
    }
    out.sort((a, b) => a.anonymisedId.compareTo(b.anonymisedId));
    return out.take(maxVehicles).toList(growable: false);
  }

  bool isFresh(CoarseVehicle vehicle) {
    final threshold = (now ?? DateTime.now()).subtract(maxAge);
    return !vehicle.seenAt.isBefore(threshold);
  }

  ExactDriver? parseExact(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    try {
      final driverId = raw['driver_id'] as String?;
      final plate = raw['vehicle_plate'] as String?;
      final lat = (raw['exact_lat'] as num?)?.toDouble();
      final lng = (raw['exact_lng'] as num?)?.toDouble();
      final heading = (raw['heading'] as num?)?.toDouble() ?? 0;
      final seenAt =
          DateTime.tryParse(raw['seen_at'] as String? ?? '') ?? DateTime.now();
      if (driverId == null || plate == null || lat == null || lng == null) {
        return null;
      }
      return ExactDriver(
        driverId: driverId,
        vehiclePlate: plate,
        exactLocation: LatLng(lat, lng),
        heading: heading,
        seenAt: seenAt,
      );
    } catch (_) {
      return null;
    }
  }

  Stream<List<CoarseVehicle>> nearbyCoarse({
    required LatLng center,
    required String category,
    double radiusMeters = 2000,
  }) {
    final factory = coarseFactory;
    if (factory == null) {
      return const Stream<List<CoarseVehicle>>.empty();
    }
    return factory(center).map(
      (raw) => filterCoarse(
        raw: raw,
        center: center,
        category: category,
        radiusMeters: radiusMeters,
      ),
    );
  }

  Stream<ExactDriver?> exactAssigned({required String rideId}) {
    final factory = exactFactory;
    if (factory == null) {
      return const Stream<ExactDriver?>.empty();
    }
    return factory(rideId).map(parseExact);
  }
}
