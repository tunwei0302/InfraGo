import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/tey/transit_stop_repository.dart';

const _center = LatLng(3.139, 101.6869);
TransitStopValue _s(String id, LatLng loc, {String? source}) =>
    TransitStopValue(
      id: id,
      name: 'Stop $id',
      location: loc,
      code: id,
      route: 'LRT Kelana Jaya',
      source: source ?? 'data.gov.my',
      lastUpdated: DateTime.now().subtract(const Duration(hours: 1)),
    );

void main() {
  test(
    'FakeTransitStopRepository returns nearest within radius, sorted',
    () async {
      final veryClose = _s('A', const LatLng(3.1392, 101.6871));
      final close = _s('B', const LatLng(3.1398, 101.688));
      final within2km = _s('C', const LatLng(3.148, 101.696));
      final farOut = _s('D', const LatLng(3.22, 101.8));
      final repo = FakeTransitStopRepository([
        farOut,
        within2km,
        close,
        veryClose,
      ]);

      final result = await repo.nearest(_center, limit: 5, radiusMeters: 2000);

      expect(result.map((n) => n.stop.id), ['A', 'B', 'C']);
      expect(result.first.distanceMeters, lessThan(result[1].distanceMeters));
      expect(result.first.distanceLabel, endsWith('m'));
    },
  );

  test('FakeTransitStopRepository caps to limit and respects radius', () async {
    final stops = List<TransitStopValue>.generate(10, (i) {
      final lat = 3.139 + (i * 0.001);
      return _s('S$i', LatLng(lat, 101.6869));
    });
    final repo = FakeTransitStopRepository(stops);
    final result = await repo.nearest(_center, limit: 3, radiusMeters: 5000);
    expect(result.map((n) => n.stop.id), ['S0', 'S1', 'S2']);
    expect(result, hasLength(3));
  });

  test(
    'FakeTransitStopRepository returns empty list for distant center',
    () async {
      final repo = FakeTransitStopRepository([_s('FAR', const LatLng(0, 0))]);
      final result = await repo.nearest(_center, limit: 5);
      expect(result, isEmpty);
    },
  );

  test('TransitStopValue stale detection', () {
    final fresh = TransitStopValue(
      id: 'F',
      name: 'Fresh',
      location: _center,
      lastUpdated: DateTime.now(),
    );
    final stale = TransitStopValue(
      id: 'S',
      name: 'Stale',
      location: _center,
      lastUpdated: DateTime.now().subtract(const Duration(hours: 7)),
    );
    final never = TransitStopValue(id: 'N', name: 'Never', location: _center);
    expect(fresh.isStale, isFalse);
    expect(stale.isStale, isTrue);
    expect(never.isStale, isTrue);
  });

  test(
    'database repository parses, filters and sorts GTFS stop rows',
    () async {
      final repository = DatabaseTransitStopRepository(
        () async => [
          {
            'stop_id': 'far',
            'stop_name': 'Far station',
            'latitude': 3.20,
            'longitude': 101.80,
            'source': 'data.gov.my GTFS Static',
            'updated_at': DateTime.now().toIso8601String(),
          },
          {
            'stop_id': 'near',
            'stop_code': 'KJ15',
            'stop_name': 'KL Sentral',
            'latitude': 3.1358,
            'longitude': 101.6865,
            'source': 'data.gov.my GTFS Static',
            'updated_at': DateTime.now().toIso8601String(),
          },
        ],
      );

      final result = await repository.nearest(
        const LatLng(3.1343, 101.6861),
        radiusMeters: 2000,
      );
      expect(result, hasLength(1));
      expect(result.single.stop.id, 'near');
      expect(result.single.stop.source, 'data.gov.my GTFS Static');
    },
  );
}
