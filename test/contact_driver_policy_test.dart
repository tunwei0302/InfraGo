import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/chat_lifecycle_policy.dart';
import 'package:infra_go/location_search_service.dart';
import 'package:infra_go/osrm_routing_service.dart';
import 'package:infra_go/trip_planner_state.dart';

class _FakeRouting extends OsrmRoutingService {
  _FakeRouting() : super(baseUrl: 'http://unused.test');

  @override
  Future<RouteResult> route(
    LatLng origin,
    LatLng destination, {
    bool useCache = true,
  }) async => RouteResult(
    points: [origin, destination],
    distanceMeters: 2500,
    durationSeconds: 420,
  );
}

GeoPlace _place(LatLng p, String name) => GeoPlace.coordinate(p, name: name);

AssignedDriverInfo _driver({String id = 'driver-1'}) => AssignedDriverInfo(
  driverId: id,
  name: 'Ahmad',
  rating: 4.8,
  vehicleMake: 'Perodua',
  vehicleModel: 'Bezza',
  vehiclePlate: 'WXY 1234',
  vehicleColor: 'White',
  etaMinutes: 3,
);

void main() {
  const pickupPoint = LatLng(3.139, 101.6869);
  const destPoint = LatLng(3.1579, 101.7132);
  final pickup = _place(pickupPoint, 'KL Sentral');
  final destination = _place(destPoint, 'KLCC');
  final search = PhotonLocationSearchService();

  group('Chat visibility rules', () {
    const policy = ChatLifecyclePolicy();

    test('Contact hidden when assigned driver id is absent', () {
      expect(policy.isContactVisible(assignedDriverId: null), isFalse);
    });

    test('Contact visible once assigned driver id exists', () {
      expect(policy.isContactVisible(assignedDriverId: 'driver-1'), isTrue);
    });

    test('state.assignedDriver null blocks onContact callback', () {
      final state = TripPlannerState(routing: _FakeRouting(), search: search);
      state.setPickup(pickup);
      state.setDestination(destination);
      state.selectVehicle(
        const VehicleOption(id: 'eco', name: 'Economy', seats: 4),
      );
      state.proceedToPickupConfirmation();
      state.submitRideRequest();
      expect(state.phase, TripPlannerPhase.searchingDriver);
      expect(state.assignedDriver, isNull);

      final onContactDriver = state.assignedDriver != null ? () {} : null;
      expect(onContactDriver, isNull);
      state.dispose();
    });

    test('state.assignedDriver present enables onContact callback', () {
      final state = TripPlannerState(routing: _FakeRouting(), search: search);
      state.setPickup(pickup);
      state.setDestination(destination);
      state.selectVehicle(
        const VehicleOption(id: 'eco', name: 'Economy', seats: 4),
      );
      state.proceedToPickupConfirmation();
      state.submitRideRequest();
      state.markDriverAssigned(_driver());
      expect(state.assignedDriver?.driverId, 'driver-1');

      final onContactDriver = state.assignedDriver != null ? () {} : null;
      expect(onContactDriver, isNotNull);
      state.dispose();
    });
  });

  group('Chat writable lifecycle', () {
    const policy = ChatLifecyclePolicy();

    for (final phase in TripPlannerPhase.values) {
      final writable =
          phase == TripPlannerPhase.driverAssigned ||
          phase == TripPlannerPhase.enRoute;
      test('phase ${phase.name}: writable=$writable', () {
        expect(policy.isWritable(phase: phase), writable);
      });
    }

    test('readonly is true only for completed and cancelled', () {
      for (final phase in TripPlannerPhase.values) {
        final readonly =
            phase == TripPlannerPhase.completed ||
            phase == TripPlannerPhase.cancelled;
        expect(
          policy.isReadonly(phase: phase),
          readonly,
          reason: 'phase ${phase.name}',
        );
      }
    });

    test('quick-message bar appears only in en_route', () {
      for (final phase in TripPlannerPhase.values) {
        expect(
          policy.showQuickMessageBar(phase: phase),
          phase == TripPlannerPhase.enRoute,
          reason: 'phase ${phase.name}',
        );
      }
    });

    test(
      'driver quick messages in en_route include arrival, delay, pickup clarification',
      () {
        final messages = policy.quickMessagesFor(
          phase: TripPlannerPhase.enRoute,
          role: ChatParticipantRole.driver,
        );
        expect(messages, contains('Arriving now'));
        expect(messages, contains('Delayed ~5 min'));
        expect(messages, contains('Can you clarify your pickup?'));
      },
    );

    test('quick messages are empty in assigned phase', () {
      expect(
        policy.quickMessagesFor(
          phase: TripPlannerPhase.driverAssigned,
          role: ChatParticipantRole.driver,
        ),
        isEmpty,
      );
      expect(
        policy.quickMessagesFor(
          phase: TripPlannerPhase.driverAssigned,
          role: ChatParticipantRole.rider,
        ),
        isEmpty,
      );
    });
  });

  group('Shared-ride rider cross-visibility denial', () {
    const policy = ChatLifecyclePolicy();
    const rideRiderA = 'rider-A';
    const rideRiderB = 'rider-B';
    const assignedDriver = 'driver-1';
    const sharedRideId = 'ride-shared-01';

    bool membership(String rideId, String userId) {
      if (rideId != sharedRideId) return false;
      return userId == rideRiderA || userId == rideRiderB;
    }

    test('Rider A cannot read messages authored by Rider B in same group', () {
      final canRead = policy.canReadMessage(
        currentUserId: rideRiderA,
        messageSenderId: rideRiderB,
        rideRiderId: rideRiderA,
        rideDriverId: assignedDriver,
        messageRideId: sharedRideId,
        membershipCheck: membership,
      );
      expect(canRead, isFalse);
    });

    test('Rider A can still read assigned driver messages', () {
      final canRead = policy.canReadMessage(
        currentUserId: rideRiderA,
        messageSenderId: assignedDriver,
        rideRiderId: rideRiderA,
        rideDriverId: assignedDriver,
        messageRideId: sharedRideId,
        membershipCheck: membership,
      );
      expect(canRead, isTrue);
    });

    test('Rider A can read own messages', () {
      final canRead = policy.canReadMessage(
        currentUserId: rideRiderA,
        messageSenderId: rideRiderA,
        rideRiderId: rideRiderA,
        rideDriverId: assignedDriver,
        messageRideId: sharedRideId,
        membershipCheck: membership,
      );
      expect(canRead, isTrue);
    });

    test('Driver can read every message on his assigned ride', () {
      for (final sender in [rideRiderA, rideRiderB, assignedDriver]) {
        final canRead = policy.canReadMessage(
          currentUserId: assignedDriver,
          messageSenderId: sender,
          rideRiderId: rideRiderA,
          rideDriverId: assignedDriver,
          messageRideId: sharedRideId,
          membershipCheck: membership,
        );
        expect(canRead, isTrue, reason: 'driver reading from $sender');
      }
    });

    test(
      'Stranger cannot read messages even if same group membership returned true',
      () {
        final canRead = policy.canReadMessage(
          currentUserId: 'stranger-99',
          messageSenderId: rideRiderA,
          rideRiderId: rideRiderA,
          rideDriverId: assignedDriver,
          messageRideId: sharedRideId,
          membershipCheck: membership,
        );
        expect(canRead, isFalse);
      },
    );
  });

  group('RLS mapping strings', () {
    test('rider SELECT rule is scoped to one ride conversation', () {
      final rule = SharedRideMessagesRlsMapping.riderSelectPolicyExpression;
      expect(rule, contains('r.id = messages.ride_id'));
      expect(
        rule,
        contains("r.rider_id = auth.uid() OR r.driver_id = auth.uid()"),
      );
      expect(rule, isNot(contains('group_id')));
    });

    test('driver SELECT rule only matches his own rides', () {
      final rule = SharedRideMessagesRlsMapping.driverSelectPolicyExpression;
      expect(rule, contains('r.driver_id = auth.uid()'));
    });

    test(
      'INSERT rules lock writable statuses to driver_assigned + en_route',
      () {
        for (final rule in [
          SharedRideMessagesRlsMapping.riderInsertPolicyExpression,
          SharedRideMessagesRlsMapping.driverInsertPolicyExpression,
        ]) {
          expect(rule, contains("'driver_assigned'"));
          expect(rule, contains("'en_route'"));
        }
      },
    );
  });
}
