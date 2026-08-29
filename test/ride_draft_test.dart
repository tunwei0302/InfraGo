import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/trip_planner_repository.dart';

void main() {
  test('RideDraft writes complete shared-ride fields', () {
    final departure = DateTime.utc(2026, 8, 30, 1, 30);
    final json = RideDraft(
      riderId: 'rider-1',
      pickupLabel: 'KL Sentral',
      destinationLabel: 'KLCC',
      pickup: const LatLng(3.1343, 101.6861),
      destination: const LatLng(3.1579, 101.7123),
      serviceType: 'shared_economy',
      passengerCount: 2,
      departureTime: departure,
      routeDistanceMeters: 4200,
      routeDurationSeconds: 720,
      pickupNote: 'Exit A',
      transitStopId: 'KJ15',
      transitStopName: 'KL Sentral LRT',
      estimatedSharedFare: 8.50,
    ).toJson();

    expect(json['status'], 'waiting_match');
    expect(json['passenger_count'], 2);
    expect(json['pickup_latitude'], 3.1343);
    expect(json['destination_longitude'], 101.7123);
    expect(json['departure_time'], departure.toIso8601String());
    expect(json['route_distance_meters'], 4200);
    expect(json['pickup_note'], 'Exit A');
    expect(json['transit_stop_id'], 'KJ15');
    expect(json['estimated_shared_fare'], 8.50);
    expect(json, isNot(contains('passengers')));
  });

  test('RideDraft uses requested lifecycle for a solo ride', () {
    final json = RideDraft(
      riderId: 'rider-1',
      pickupLabel: 'A',
      destinationLabel: 'B',
      pickup: const LatLng(3.1, 101.6),
      destination: const LatLng(3.2, 101.7),
      serviceType: 'economy_4',
      passengerCount: 1,
      departureTime: DateTime.utc(2026),
      routeDistanceMeters: 1000,
      routeDurationSeconds: 300,
    ).toJson();

    expect(json['status'], 'requested');
    expect(json['service_type'], 'economy_4');
  });
}
