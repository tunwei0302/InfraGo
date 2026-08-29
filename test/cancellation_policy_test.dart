import 'package:flutter_test/flutter_test.dart';

import 'package:infra_go/cancellation_policy.dart';

void main() {
  const fare = 20.0;
  final acceptedAt = DateTime.utc(2026, 8, 29, 12, 0, 0);

  group('driver/system cancellation', () {
    test('is always free regardless of ride state', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.driver,
        rideStatus: 'en_route',
        confirmedFare: fare,
        now: acceptedAt.add(const Duration(hours: 1)),
        acceptedAt: acceptedAt,
      );
      expect(outcome.isFree, isTrue);
      expect(outcome.fee, 0);
      expect(outcome.reason, 'driver_or_system_cancellation');
    });
  });

  group('driver over pickup ETA', () {
    test('more than 5 minutes late is free', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'driver_assigned',
        confirmedFare: fare,
        now: acceptedAt.add(const Duration(minutes: 10)),
        acceptedAt: acceptedAt,
        driverLateMinutes: 6,
      );
      expect(outcome.isFree, isTrue);
      expect(outcome.reason, 'driver_over_eta');
    });

    test('exactly 5 minutes late is not treated as over ETA', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'driver_assigned',
        confirmedFare: fare,
        now: acceptedAt.add(const Duration(minutes: 10)),
        acceptedAt: acceptedAt,
        driverLateMinutes: 5,
      );
      expect(outcome.isFree, isFalse);
      expect(outcome.reason, 'post_grace_fee');
    });
  });

  group('before driver assignment', () {
    test('is free when no acceptedAt exists', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'waiting_match',
        confirmedFare: fare,
        now: DateTime.utc(2026, 8, 29, 12, 5, 0),
      );
      expect(outcome.isFree, isTrue);
      expect(outcome.reason, 'before_driver_assignment');
    });
  });

  group('grace period boundary', () {
    test('free just before the 3-minute mark', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'driver_assigned',
        confirmedFare: fare,
        now: acceptedAt.add(const Duration(minutes: 2, seconds: 59)),
        acceptedAt: acceptedAt,
      );
      expect(outcome.isFree, isTrue);
      expect(outcome.reason, 'within_grace_period');
    });

    test('fee applies exactly at the 3-minute mark', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'driver_assigned',
        confirmedFare: fare,
        now: acceptedAt.add(const Duration(minutes: 3)),
        acceptedAt: acceptedAt,
      );
      expect(outcome.isFree, isFalse);
      expect(outcome.reason, 'post_grace_fee');
    });
  });

  group('post-grace fee clamp', () {
    test('20% of fare when within the RM2-RM5 band', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'driver_assigned',
        confirmedFare: 15.0,
        now: acceptedAt.add(const Duration(minutes: 5)),
        acceptedAt: acceptedAt,
      );
      expect(outcome.fee, 3.0);
    });

    test('clamps to the RM2 minimum on a small fare', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'driver_assigned',
        confirmedFare: 5.0,
        now: acceptedAt.add(const Duration(minutes: 5)),
        acceptedAt: acceptedAt,
      );
      expect(outcome.fee, 2.0);
    });

    test('clamps to the RM5 maximum on a large fare', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'driver_assigned',
        confirmedFare: 100.0,
        now: acceptedAt.add(const Duration(minutes: 5)),
        acceptedAt: acceptedAt,
      );
      expect(outcome.fee, 5.0);
    });
  });

  group('scheduled ride cutoff', () {
    final departureTime = DateTime.utc(2026, 8, 29, 15, 0, 0);

    test('stays free more than 15 minutes before departure even after grace expires', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'driver_assigned',
        confirmedFare: fare,
        now: departureTime.subtract(const Duration(minutes: 20)),
        acceptedAt: acceptedAt,
        isScheduled: true,
        departureTime: departureTime,
      );
      expect(outcome.isFree, isTrue);
      expect(outcome.reason, 'scheduled_outside_cutoff');
    });

    test('fee applies exactly at the 15-minute cutoff', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'driver_assigned',
        confirmedFare: fare,
        now: departureTime.subtract(const Duration(minutes: 15)),
        acceptedAt: acceptedAt,
        isScheduled: true,
        departureTime: departureTime,
      );
      expect(outcome.isFree, isFalse);
      expect(outcome.reason, 'post_grace_fee');
    });

    test('non-scheduled rides ignore the scheduled cutoff entirely', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'driver_assigned',
        confirmedFare: fare,
        now: acceptedAt.add(const Duration(minutes: 5)),
        acceptedAt: acceptedAt,
        isScheduled: false,
      );
      expect(outcome.isFree, isFalse);
      expect(outcome.reason, 'post_grace_fee');
    });
  });

  group('en_route and terminal statuses', () {
    test('en_route is no longer self-cancellable under this policy', () {
      final outcome = CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'en_route',
        confirmedFare: fare,
        now: acceptedAt.add(const Duration(minutes: 20)),
        acceptedAt: acceptedAt,
      );
      expect(outcome.cancellable, isFalse);
    });

    test('completed and cancelled rides are not cancellable', () {
      for (final status in ['completed', 'cancelled']) {
        final outcome = CancellationPolicy.evaluate(
          cancelledBy: CancelledBy.rider,
          rideStatus: status,
          confirmedFare: fare,
          now: acceptedAt.add(const Duration(minutes: 20)),
          acceptedAt: acceptedAt,
        );
        expect(outcome.cancellable, isFalse, reason: status);
      }
    });
  });

  test('rejects a negative confirmed fare', () {
    expect(
      () => CancellationPolicy.evaluate(
        cancelledBy: CancelledBy.rider,
        rideStatus: 'driver_assigned',
        confirmedFare: -1,
        now: acceptedAt,
        acceptedAt: acceptedAt,
      ),
      throwsArgumentError,
    );
  });
}
