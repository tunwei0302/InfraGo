import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Guard for the Kueh/Heng boundary: rider chat opens only when a ride is
// driver_assigned, so any acceptance path that writes a different status
// silently breaks Contact Driver for passengers.
void main() {
  test('solo acceptance writes driver_id with the driver_assigned status', () {
    final source = File('lib/heng/available_orders_screen.dart').readAsStringSync();
    final acceptStart = source.indexOf('Future<void> _acceptRide');
    final buildStart = source.indexOf('@override', acceptStart);
    final acceptMethod = source.substring(acceptStart, buildStart);
    expect(
      acceptMethod,
      contains("'driver_id': supabase.auth.currentUser!.id"),
    );
    expect(acceptMethod, contains("'status': 'driver_assigned'"));
    expect(acceptMethod, isNot(contains("'accepted'")));
  });
}
