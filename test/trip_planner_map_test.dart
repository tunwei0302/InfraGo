import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/kueh/trip_planner_map_screen.dart';
import 'package:infra_go/kueh/trip_planner_state.dart';

void main() {
  test('database errors are converted to rider-friendly shared messages', () {
    expect(
      sharedMatchFailureMessage(Exception('PGRST202 function missing')),
      'Shared Ride is being updated. Please retry in a moment.',
    );
    expect(
      sharedMatchFailureMessage(Exception('network timeout')),
      'Shared matching is temporarily unavailable. We will keep trying.',
    );
  });

  test('formats map coordinates consistently', () {
    expect(
      formatCoordinate(const LatLng(3.139, 101.6869)),
      '3.13900, 101.68690',
    );
  });

  test('calculates straight-line distance between selected points', () {
    const origin = LatLng(3.139, 101.6869);
    const destination = LatLng(3.1478, 101.6953);

    final distance = straightLineDistanceMeters(origin, destination);

    expect(distance, greaterThan(1000));
    expect(distance, lessThan(2000));
  });

  test(
    'driver proximity detects arrival inside the 100 metre pickup radius',
    () {
      const pickup = LatLng(3.139, 101.6869);
      expect(hasDriverReachedPickup(pickup, pickup), isTrue);
      expect(
        hasDriverReachedPickup(const LatLng(3.141, 101.6869), pickup),
        isFalse,
      );
    },
  );

  test(
    'live ETA targets pickup before collection and destination after it',
    () {
      const pickup = LatLng(3.139, 101.6869);
      const destination = LatLng(3.1579, 101.7132);
      expect(
        assignedDriverEtaTarget(
          phase: TripPlannerPhase.driverAssigned,
          pickup: pickup,
          destination: destination,
        ),
        pickup,
      );
      expect(
        assignedDriverEtaTarget(
          phase: TripPlannerPhase.enRoute,
          pickup: pickup,
          destination: destination,
        ),
        destination,
      );
    },
  );
}
