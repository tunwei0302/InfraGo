class GroupMemberStops {
  const GroupMemberStops({
    required this.rideId,
    required this.pickupOrderIndex,
    required this.destinationOrderIndex,
  });

  final String rideId;
  final int pickupOrderIndex;
  final int destinationOrderIndex;
}

class GroupStopAction {
  const GroupStopAction({
    required this.index,
    required this.riderNumber,
    required this.isPickup,
    required this.isFinal,
  });

  final int index;
  final int riderNumber;
  final bool isPickup;
  final bool isFinal;

  String get code => '${isPickup ? 'P' : 'D'}$riderNumber';

  String get buttonLabel {
    if (isPickup) return 'Mark Rider $riderNumber picked up';
    if (isFinal) return 'Mark Rider $riderNumber dropped off & complete';
    return 'Mark Rider $riderNumber dropped off';
  }
}

void _validateStopOrder(List<int> stopOrder) {
  if (stopOrder.length != 4 ||
      stopOrder.toSet().length != 4 ||
      !stopOrder.toSet().containsAll(const [0, 1, 2, 3])) {
    throw const FormatException('Shared group stop order must contain 0–3.');
  }
}

Map<String, int> buildGroupRideSlots({
  required List<int> stopOrder,
  required Iterable<GroupMemberStops> members,
}) {
  _validateStopOrder(stopOrder);
  final slots = <String, int>{};
  final usedSlots = <int>{};
  for (final member in members) {
    if (member.pickupOrderIndex < 0 ||
        member.pickupOrderIndex >= stopOrder.length ||
        member.destinationOrderIndex < 0 ||
        member.destinationOrderIndex >= stopOrder.length) {
      throw const FormatException('Shared group member indexes are invalid.');
    }
    final pickupCode = stopOrder[member.pickupOrderIndex];
    final destinationCode = stopOrder[member.destinationOrderIndex];
    if (pickupCode < 0 || pickupCode > 1 || destinationCode != pickupCode + 2) {
      throw const FormatException(
        'Shared group member mapping is inconsistent.',
      );
    }
    if (!usedSlots.add(pickupCode)) {
      throw const FormatException('Two rides cannot use the same rider slot.');
    }
    slots[member.rideId] = pickupCode;
  }
  if (slots.length != 2) {
    throw const FormatException('Shared group must contain two rides.');
  }
  return slots;
}

GroupStopAction currentGroupStopAction({
  required List<int> stopOrder,
  required int? storedIndex,
}) {
  _validateStopOrder(stopOrder);
  final index = activeGroupStopIndex(storedIndex, stopOrder.length);
  final code = stopOrder[index];
  return GroupStopAction(
    index: index,
    riderNumber: (code % 2) + 1,
    isPickup: code < 2,
    isFinal: index == stopOrder.length - 1,
  );
}

int activeGroupStopIndex(int? storedIndex, int stopCount) {
  if (stopCount <= 0) throw ArgumentError.value(stopCount, 'stopCount');
  if (storedIndex == null) return 0;
  return storedIndex.clamp(0, stopCount - 1);
}

int? nextGroupStopIndex(int currentIndex, int stopCount) {
  if (currentIndex < 0 || currentIndex >= stopCount) {
    throw ArgumentError.value(currentIndex, 'currentIndex');
  }
  return currentIndex + 1 < stopCount ? currentIndex + 1 : null;
}
