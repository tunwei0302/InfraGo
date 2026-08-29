import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/vehicle_presence_service.dart';

const _center = LatLng(3.139, 101.6869);
const _close = LatLng(3.1395, 101.6875);
const _far = LatLng(3.2, 101.8);

Map<String, dynamic> _raw({
  required String anonymisedId,
  required LatLng loc,
  required DateTime seenAt,
  String category = 'economy',
  bool online = true,
  bool assigned = false,
}) {
  return {
    'anonymised_id': anonymisedId,
    'coarse_lat': loc.latitude,
    'coarse_lng': loc.longitude,
    'vehicle_categories': [category],
    'last_seen_at': seenAt.toIso8601String(),
    'is_online': online,
    'is_assigned': assigned,
  };
}

void main() {
  group('filterCoarse', () {
    final now = DateTime.utc(2026, 8, 28, 12, 0, 0);
    final fresh = now.subtract(const Duration(seconds: 10));
    final stale = now.subtract(const Duration(seconds: 90));

    test('drops stale, offline, assigned, and out-of-radius entries', () {
      final svc = VehiclePresenceService(now: now);
      final raw = [
        _raw(anonymisedId: 'A', loc: _close, seenAt: fresh),
        _raw(anonymisedId: 'B', loc: _close, seenAt: stale),
        _raw(anonymisedId: 'C', loc: _far, seenAt: fresh),
        _raw(anonymisedId: 'D', loc: _close, seenAt: fresh, online: false),
        _raw(anonymisedId: 'E', loc: _close, seenAt: fresh, assigned: true),
        _raw(anonymisedId: 'F', loc: _close, seenAt: fresh, category: 'suv'),
      ];
      final result = svc.filterCoarse(
        raw: raw,
        center: _center,
        category: 'economy',
        radiusMeters: 2000,
      );
      expect(result.map((v) => v.anonymisedId).toList(), ['A']);
    });

    test('empty result when no compatible entries', () {
      final svc = VehiclePresenceService(now: now);
      final result = svc.filterCoarse(
        raw: [
          _raw(anonymisedId: 'X', loc: _close, seenAt: fresh, category: 'suv'),
        ],
        center: _center,
        category: 'economy',
        radiusMeters: 2000,
      );
      expect(result, isEmpty);
    });

    test('sorted deterministically by anonymisedId', () {
      final svc = VehiclePresenceService(now: now);
      final result = svc.filterCoarse(
        raw: [
          _raw(anonymisedId: 'Z', loc: _close, seenAt: fresh),
          _raw(anonymisedId: 'A', loc: _close, seenAt: fresh),
          _raw(anonymisedId: 'M', loc: _close, seenAt: fresh),
        ],
        center: _center,
        category: 'economy',
        radiusMeters: 5000,
      );
      expect(result.map((v) => v.anonymisedId), ['A', 'M', 'Z']);
    });

    test('isFresh returns false for entries over 60 seconds', () {
      final svc = VehiclePresenceService(now: now);
      final vehicle = CoarseVehicle(
        anonymisedId: 'V1',
        coarseLocation: _close,
        compatibleCategories: {'economy'},
        seenAt: stale,
      );
      expect(svc.isFresh(vehicle), isFalse);
    });
  });

  group('parseExact', () {
    test('returns null when required fields are missing', () {
      final svc = VehiclePresenceService();
      expect(
        svc.parseExact({'driver_id': null, 'vehicle_plate': 'ABC'}),
        isNull,
      );
    });

    test('parses exact driver payload correctly', () {
      final svc = VehiclePresenceService();
      final now = DateTime.now();
      final result = svc.parseExact({
        'driver_id': 'd_123',
        'vehicle_plate': 'WEX1234',
        'exact_lat': 3.14,
        'exact_lng': 101.69,
        'heading': 180.0,
        'seen_at': now.toIso8601String(),
      });
      expect(result, isNotNull);
      expect(result!.driverId, 'd_123');
      expect(result.vehiclePlate, 'WEX1234');
      expect(result.exactLocation, const LatLng(3.14, 101.69));
      expect(result.heading, 180);
    });
  });

  group('nearbyCoarse stream integration', () {
    test('applies filter to each stream event', () async {
      final now = DateTime.utc(2026, 8, 28, 12, 0, 0);
      final controller = StreamController<List<Map<String, dynamic>>>();
      final svc = VehiclePresenceService(
        now: now,
        coarseFactory: (_) => controller.stream,
      );
      final items = <List<CoarseVehicle>>[];
      final sub = svc
          .nearbyCoarse(center: _center, category: 'economy')
          .listen(items.add);

      final fresh = now.subtract(const Duration(seconds: 10));
      controller.add([
        _raw(anonymisedId: 'A', loc: _close, seenAt: fresh),
        _raw(anonymisedId: 'B', loc: _far, seenAt: fresh),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(items.last.map((v) => v.anonymisedId), ['A']);

      await sub.cancel();
      await controller.close();
    });
  });
}
