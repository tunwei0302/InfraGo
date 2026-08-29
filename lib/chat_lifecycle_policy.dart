import 'trip_planner_state.dart';

enum ChatParticipantRole { rider, driver }

class ChatLifecyclePolicy {
  const ChatLifecyclePolicy();

  bool isContactVisible({required String? assignedDriverId}) =>
      assignedDriverId != null;

  bool isReadonly({required TripPlannerPhase phase}) =>
      phase == TripPlannerPhase.completed ||
      phase == TripPlannerPhase.cancelled;

  bool isWritable({required TripPlannerPhase phase}) =>
      phase == TripPlannerPhase.driverAssigned ||
      phase == TripPlannerPhase.enRoute;

  bool showQuickMessageBar({required TripPlannerPhase phase}) =>
      phase == TripPlannerPhase.enRoute;

  List<String> quickMessagesFor({
    required TripPlannerPhase phase,
    required ChatParticipantRole role,
  }) {
    if (!showQuickMessageBar(phase: phase)) return const [];
    if (role == ChatParticipantRole.driver) {
      return const [
        'Arriving now',
        'Delayed ~5 min',
        'Can you clarify your pickup?',
      ];
    }
    return const [
      'I am walking to the pickup',
      'Please call me when you are nearby',
    ];
  }

  bool canReadMessage({
    required String currentUserId,
    required String messageSenderId,
    required String rideRiderId,
    required String? rideDriverId,
    String? messageRideId,
    bool Function(String rideId, String userId)? membershipCheck,
  }) {
    final canReadAsRider = currentUserId == rideRiderId;
    final canReadAsDriver =
        rideDriverId != null && currentUserId == rideDriverId;
    if (!canReadAsRider && !canReadAsDriver) return false;

    if (messageRideId != null && membershipCheck != null) {
      if (canReadAsRider &&
          messageSenderId != rideRiderId &&
          messageSenderId != rideDriverId) {
        final senderInSameGroup = membershipCheck(
          messageRideId,
          messageSenderId,
        );
        if (senderInSameGroup && messageSenderId != rideDriverId) {
          return false;
        }
      }
    }
    return true;
  }
}

class SharedRideMessagesRlsMapping {
  const SharedRideMessagesRlsMapping();

  static const String riderSelectPolicyExpression =
      "EXISTS (SELECT 1 FROM rides r "
      "WHERE r.id = messages.ride_id "
      "AND (r.rider_id = auth.uid() OR r.driver_id = auth.uid()))";

  static const String driverSelectPolicyExpression =
      "EXISTS (SELECT 1 FROM rides r "
      "WHERE r.id = messages.ride_id "
      "AND r.driver_id = auth.uid())";

  static const String riderInsertPolicyExpression =
      "EXISTS (SELECT 1 FROM rides r "
      "WHERE r.id = messages.ride_id "
      "AND r.rider_id = auth.uid() "
      "AND r.status IN ('driver_assigned', 'en_route'))";

  static const String driverInsertPolicyExpression =
      "EXISTS (SELECT 1 FROM rides r "
      "WHERE r.id = messages.ride_id "
      "AND r.driver_id = auth.uid() "
      "AND r.status IN ('driver_assigned', 'en_route'))";
}
