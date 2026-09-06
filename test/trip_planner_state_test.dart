import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/kueh/location_search_service.dart';
import 'package:infra_go/kueh/osrm_routing_service.dart';
import 'package:infra_go/kueh/trip_planner_state.dart';

class _FakeRouting extends OsrmRoutingService {
  _FakeRouting() : super(baseUrl: 'http://unused.test');

  @override
  Future<RouteResult> route(
    LatLng origin,
    LatLng destination, {
    bool useCache = true,
  }) async {
    return RouteResult(
      points: [origin, destination],
      distanceMeters: 2500,
      durationSeconds: 420,
    );
  }
}

class _FailingRouting extends OsrmRoutingService {
  _FailingRouting() : super(baseUrl: 'http://unused.test');

  @override
  Future<RouteResult> route(
    LatLng origin,
    LatLng destination, {
    bool useCache = true,
  }) async {
    throw const RoutingException('routing down');
  }
}

GeoPlace _place(LatLng p, String name) => GeoPlace.coordinate(p, name: name);

void main() {
  const pickupPoint = LatLng(3.139, 101.6869);
  const destPoint = LatLng(3.1579, 101.7132);
  final pickup = _place(pickupPoint, 'KL Sentral');
  final destination = _place(destPoint, 'KLCC');
  final search = PhotonLocationSearchService();

  group('phase transitions', () {
    test('starts in explore, advances to routePreview with pickup+dest', () {
      final state = TripPlannerState(routing: _FakeRouting(), search: search);
      expect(state.phase, TripPlannerPhase.explore);

      state.setPickup(pickup);
      expect(state.phase, TripPlannerPhase.explore);

      state.setDestination(destination);
      expect(state.phase, TripPlannerPhase.routePreview);
      state.dispose();
    });

    test('vehicle options and pickup confirmation flow in order', () {
      final state = TripPlannerState(routing: _FakeRouting(), search: search);
      state.setPickup(pickup);
      state.setDestination(destination);
      expect(state.phase, TripPlannerPhase.routePreview);

      const opt = VehicleOption(id: 'eco', name: 'Economy', seats: 4);
      state.selectVehicle(opt);
      expect(state.phase, TripPlannerPhase.vehicleOptions);
      expect(state.selectedVehicle?.id, 'eco');

      state.proceedToPickupConfirmation();
      expect(state.phase, TripPlannerPhase.pickupConfirmation);
      state.dispose();
    });
  });

  group('goBack navigation', () {
    test('back from routePreview returns to explore', () {
      final state = TripPlannerState(routing: _FakeRouting(), search: search);
      state.setPickup(pickup);
      state.setDestination(destination);
      state.goBack();
      expect(state.phase, TripPlannerPhase.explore);
      state.dispose();
    });

    test(
      'back from vehicleOptions clears selection, returns to routePreview',
      () {
        final state = TripPlannerState(routing: _FakeRouting(), search: search);
        state.setPickup(pickup);
        state.setDestination(destination);
        const opt = VehicleOption(id: 'eco', name: 'Economy', seats: 4);
        state.selectVehicle(opt);
        state.goBack();
        expect(state.phase, TripPlannerPhase.routePreview);
        expect(state.selectedVehicle, isNull);
        state.dispose();
      },
    );

    test('back from pickupConfirmation returns to vehicleOptions', () {
      final state = TripPlannerState(routing: _FakeRouting(), search: search);
      state.setPickup(pickup);
      state.setDestination(destination);
      const opt = VehicleOption(id: 'eco', name: 'Economy', seats: 4);
      state.selectVehicle(opt);
      state.proceedToPickupConfirmation();
      state.goBack();
      expect(state.phase, TripPlannerPhase.vehicleOptions);
      expect(state.selectedVehicle?.id, 'eco');
      state.dispose();
    });
  });

  group('cancel and reset', () {
    test(
      'cancel tears down subscriptions and moves to cancelled phase',
      () async {
        final state = TripPlannerState(routing: _FakeRouting(), search: search);
        var cancelled = false;
        state.onCancelRequested(() => cancelled = true);

        state.setPickup(pickup);
        state.setDestination(destination);
        const opt = VehicleOption(id: 'eco', name: 'Economy', seats: 4);
        state.selectVehicle(opt);
        state.proceedToPickupConfirmation();
        await state.submitRideRequest();
        expect(state.phase, TripPlannerPhase.searchingDriver);

        state.cancelCurrentFlow(reason: 'user changed mind');
        expect(state.phase, TripPlannerPhase.cancelled);
        expect(state.errorMessage, 'user changed mind');
        expect(cancelled, isTrue);
        state.dispose();
      },
    );

    test('resetToExplore keeps provided pickup and clears active state', () {
      final state = TripPlannerState(routing: _FakeRouting(), search: search);
      state.setPickup(pickup);
      state.setDestination(destination);
      state.setPickupNote('by the red bench');
      state.cancelCurrentFlow();
      state.resetToExplore(keepPickup: pickup);
      expect(state.phase, TripPlannerPhase.explore);
      expect(state.pickup?.name, 'KL Sentral');
      expect(state.destination, isNull);
      expect(state.pickupNote, isNull);
      state.dispose();
    });
  });

  group('submit lifecycle', () {
    test('submitRideRequest fires callbacks, starts searching phase', () async {
      final state = TripPlannerState(routing: _FakeRouting(), search: search);
      var submitted = 0;
      state.onRequestSubmitted(() => submitted++);
      state.setPickup(pickup);
      state.setDestination(destination);
      const opt = VehicleOption(id: 'eco', name: 'Economy', seats: 4);
      state.selectVehicle(opt);
      state.proceedToPickupConfirmation();
      final ok = await state.submitRideRequest();
      expect(ok, isTrue);
      expect(submitted, 1);
      expect(state.phase, TripPlannerPhase.searchingDriver);
      expect(state.searchingSince, isNotNull);
      state.dispose();
    });

    test('submit fails without vehicle selection', () async {
      final state = TripPlannerState(routing: _FakeRouting(), search: search);
      state.setPickup(pickup);
      state.setDestination(destination);
      final ok = await state.submitRideRequest();
      expect(ok, isFalse);
      expect(state.phase, TripPlannerPhase.routePreview);
      state.dispose();
    });

    test('database callback failure does not enter searching state', () async {
      final state = TripPlannerState(routing: _FakeRouting(), search: search);
      state.onRequestSubmitted(() async => throw Exception('insert failed'));
      state.setPickup(pickup);
      state.setDestination(destination);
      state.selectVehicle(
        const VehicleOption(id: 'economy_4', name: 'Economy', seats: 4),
      );
      state.proceedToPickupConfirmation();

      expect(await state.submitRideRequest(), isFalse);
      expect(state.phase, TripPlannerPhase.pickupConfirmation);
      expect(state.errorMessage, contains('insert failed'));
      state.dispose();
    });
  });

  group('ride preferences', () {
    test('six-seater accepts six passengers and a valid schedule', () {
      final state = TripPlannerState(routing: _FakeRouting(), search: search);
      state.setPickup(pickup);
      state.setDestination(destination);
      state.selectVehicle(
        const VehicleOption(id: 'six_seater', name: '6-seater', seats: 6),
      );
      final departure = DateTime.now().add(const Duration(minutes: 30));
      state.setRidePreferences(
        passengerCount: 6,
        scheduledDeparture: departure,
      );
      expect(state.passengerCount, 6);
      expect(state.scheduledDeparture, departure);
      state.dispose();
    });

    test('shared economy rejects more than two passengers', () {
      final state = TripPlannerState(routing: _FakeRouting(), search: search);
      state.setPickup(pickup);
      state.setDestination(destination);
      state.selectVehicle(
        const VehicleOption(
          id: 'shared_economy',
          name: 'Shared',
          seats: 4,
          isShared: true,
        ),
      );
      expect(
        () => state.setRidePreferences(passengerCount: 3),
        throwsArgumentError,
      );
      state.dispose();
    });

    test(
      'three-minute free window starts only when driver is assigned',
      () async {
        final state = TripPlannerState(routing: _FakeRouting(), search: search);
        state.setPickup(pickup);
        state.setDestination(destination);
        state.selectVehicle(
          const VehicleOption(id: 'economy_4', name: 'Economy', seats: 4),
        );
        state.proceedToPickupConfirmation();
        await state.submitRideRequest();
        expect(state.cancelCountdownSeconds, 0);
        expect(state.canCancelForFree, isTrue);

        state.markDriverAssigned(
          const AssignedDriverInfo(
            driverId: 'driver-1',
            name: 'Driver',
            rating: 4.9,
            vehicleMake: 'Perodua',
            vehicleModel: 'Myvi',
            vehiclePlate: 'ABC1234',
            vehicleColor: 'Blue',
            etaMinutes: 4,
          ),
        );
        expect(state.cancelCountdownSeconds, 180);
        state.dispose();
      },
    );
  });

  group('route computation', () {
    test(
      'routeReady and distance/ETA set after successful computation',
      () async {
        final state = TripPlannerState(routing: _FakeRouting(), search: search);
        state.setPickup(pickup);
        state.setDestination(destination);
        await Future<void>.delayed(Duration.zero);
        expect(state.routeReady, isTrue);
        expect(state.route?.distanceMeters, 2500);
        expect(state.route?.durationSeconds, 420);
        state.dispose();
      },
    );

    test(
      'routing failure sets errorMessage, keeps phase as explore/routePreview',
      () async {
        final state = TripPlannerState(
          routing: _FailingRouting(),
          search: search,
        );
        state.setPickup(pickup);
        state.setDestination(destination);
        await Future<void>.delayed(Duration.zero);
        expect(state.errorMessage, 'routing down');
        expect(state.route, isNull);
        state.dispose();
      },
    );
  });
}
