import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/trip_planner_map_screen.dart';

void main() {
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
}
