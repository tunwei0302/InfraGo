import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:infra_go/kueh/driver_assigned_panel.dart';
import 'package:infra_go/kueh/trip_planner_state.dart';

void main() {
  const driver = AssignedDriverInfo(
    driverId: 'driver-1',
    name: 'Ahmad',
    rating: 4.8,
    vehicleMake: 'Perodua',
    vehicleModel: 'Bezza',
    vehiclePlate: 'WXY 1234',
    vehicleColor: 'White',
    etaMinutes: 8,
    remainingDistanceMeters: 4200,
    tripProgress: 0.35,
  );

  testWidgets('en-route panel shows destination distance, ETA and progress', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DriverAssignedPanel(
            driver: driver,
            phase: TripPlannerPhase.enRoute,
            cancelCountdownSeconds: 0,
            canCancelForFree: false,
            destinationName: 'KLCC',
          ),
        ),
      ),
    );

    expect(find.text('En route to destination'), findsOneWidget);
    expect(find.text('About 8 min to destination'), findsOneWidget);
    expect(find.text('4.2 km remaining'), findsOneWidget);
    expect(find.text('Destination · KLCC'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('pickup proximity is described as arrival, not en-route', (
    tester,
  ) async {
    const atPickup = AssignedDriverInfo(
      driverId: 'driver-1',
      name: 'Ahmad',
      rating: 4.8,
      vehicleMake: 'Perodua',
      vehicleModel: 'Bezza',
      vehiclePlate: 'WXY 1234',
      vehicleColor: 'White',
      etaMinutes: 0,
      isAtPickup: true,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DriverAssignedPanel(
            driver: atPickup,
            phase: TripPlannerPhase.driverAssigned,
            cancelCountdownSeconds: 0,
            canCancelForFree: false,
          ),
        ),
      ),
    );

    expect(find.text('Driver is at pickup'), findsOneWidget);
    expect(find.text('En route to destination'), findsNothing);
  });
}
