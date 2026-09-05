import 'package:flutter_test/flutter_test.dart';

import 'package:infra_go/kueh/trip_planner_repository.dart';

void main() {
  test('matched lifecycle snapshot carries its shared group id', () {
    final snapshot = RideLifecycleSnapshot.fromJson({
      'id': 'ride-a',
      'status': 'matched',
      'driver_id': null,
      'group_id': 'group-1',
    });

    expect(snapshot.id, 'ride-a');
    expect(snapshot.status, 'matched');
    expect(snapshot.driverId, isNull);
    expect(snapshot.groupId, 'group-1');
  });
}
