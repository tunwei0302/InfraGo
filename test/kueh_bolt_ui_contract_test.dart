import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'lib/kueh/trip_planner_map_screen.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  test('map uses one Bolt-style top search and bottom action hierarchy', () {
    expect(source, contains("key: const Key('bolt_trip_panel')"));
    expect(source, contains("key: const Key('bolt_search_panel')"));
    expect(source, contains("key: const Key('primary_trip_action')"));
    expect(source, contains("key: const Key('map_control_transit')"));
    expect(source, contains("key: const Key('map_control_location')"));
    expect(
      source,
      isNot(contains('appBar: AppBar(title: const Text(\'Plan a ride\')')),
    );
  });

  test(
    'primary ride action opens all vehicle choices, not a preselected car',
    () {
      expect(
        source,
        contains(
          'onChooseVehicle: route != null\n'
          '                    ? () => unawaited(_openVehicleOptionsSheet())',
        ),
      );
      expect(source, isNot(contains('_vehicleOptionsForRoute(route).first')));
    },
  );

  test('legacy duplicate cards and booking-review path stay removed', () {
    expect(source, isNot(contains('class _ActiveRidePanel')));
    expect(source, isNot(contains('class _TransitBadge')));
    expect(source, isNot(contains('class _NoNearbyDriversBanner')));
    expect(source, isNot(contains('class TripPlanReviewScreen')));
    expect(source, isNot(contains('BookingFormSheet')));
  });
}
