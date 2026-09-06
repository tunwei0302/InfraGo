enum CancelledBy { rider, driver, system }

class CancellationOutcome {
  const CancellationOutcome({
    required this.cancellable,
    required this.isFree,
    required this.fee,
    required this.reason,
  });

  final bool cancellable;
  final bool isFree;
  final double fee;
  final String reason;
}

class CancellationPolicy {
  const CancellationPolicy._();

  static const String policyVersion = 'cancel_v1';
  static const Duration gracePeriod = Duration(minutes: 3);
  static const Duration scheduledFreeWindow = Duration(minutes: 15);
  static const double feePercent = 0.20;
  static const double minFee = 2.0;
  static const double maxFee = 5.0;
  static const int driverLateFreeMinutes = 5;

  static CancellationOutcome evaluate({
    required CancelledBy cancelledBy,
    required String rideStatus,
    required double confirmedFare,
    required DateTime now,
    DateTime? acceptedAt,
    bool isScheduled = false,
    DateTime? departureTime,
    int? driverLateMinutes,
  }) {
    if (confirmedFare < 0) {
      throw ArgumentError('confirmedFare must not be negative');
    }

    if (cancelledBy != CancelledBy.rider) {
      return const CancellationOutcome(
        cancellable: true,
        isFree: true,
        fee: 0,
        reason: 'driver_or_system_cancellation',
      );
    }

    if (driverLateMinutes != null &&
        driverLateMinutes > driverLateFreeMinutes) {
      return const CancellationOutcome(
        cancellable: true,
        isFree: true,
        fee: 0,
        reason: 'driver_over_eta',
      );
    }

    if (rideStatus == 'en_route' ||
        rideStatus == 'completed' ||
        rideStatus == 'cancelled') {
      return CancellationOutcome(
        cancellable: false,
        isFree: false,
        fee: 0,
        reason: 'not_cancellable_$rideStatus',
      );
    }

    if (acceptedAt == null) {
      return const CancellationOutcome(
        cancellable: true,
        isFree: true,
        fee: 0,
        reason: 'before_driver_assignment',
      );
    }

    final graceExpiry = acceptedAt.add(gracePeriod);
    if (now.isBefore(graceExpiry)) {
      return const CancellationOutcome(
        cancellable: true,
        isFree: true,
        fee: 0,
        reason: 'within_grace_period',
      );
    }

    if (isScheduled && departureTime != null) {
      final scheduledCutoff = departureTime.subtract(scheduledFreeWindow);
      if (now.isBefore(scheduledCutoff)) {
        return const CancellationOutcome(
          cancellable: true,
          isFree: true,
          fee: 0,
          reason: 'scheduled_outside_cutoff',
        );
      }
    }

    final fee = _roundMoney((confirmedFare * feePercent).clamp(minFee, maxFee));
    return CancellationOutcome(
      cancellable: true,
      isFree: false,
      fee: fee,
      reason: 'post_grace_fee',
    );
  }

  static double _roundMoney(double value) => (value * 100).round() / 100;
}
