import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/kueh/location_search_service.dart';
import 'package:infra_go/kueh/pickup_confirmation_sheet.dart';
import 'package:infra_go/kueh/trip_planner_state.dart';

void main() {
  testWidgets('shows the selected transit connection for a shared ride', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => PickupConfirmationSheet.show(
                context,
                pickup: const GeoPlace(
                  name: 'Home',
                  address: 'Kuala Lumpur',
                  point: LatLng(3.1390, 101.6869),
                ),
                destination: const GeoPlace(
                  name: 'Office',
                  address: 'Kuala Lumpur',
                  point: LatLng(3.1580, 101.7113),
                ),
                vehicle: const VehicleOption(
                  id: 'shared_economy',
                  name: 'Shared Economy',
                  seats: 4,
                  isShared: true,
                  estimatedFareMin: 8.25,
                  estimatedFareMax: 8.25,
                ),
                route: const TripPlanRoute(
                  points: [LatLng(3.1390, 101.6869), LatLng(3.1580, 101.7113)],
                  distanceMeters: 5000,
                  durationSeconds: 600,
                ),
                passengerCount: 1,
                transitStopName: 'Pasar Seni',
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Transit connection: Pasar Seni'), findsOneWidget);
  });
}
