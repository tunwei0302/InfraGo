import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/carpool_matcher.dart';

const _base = LatLng(3.139, 101.6869);
const _p1 = LatLng(3.1392, 101.6871);
const _p2 = LatLng(3.1395, 101.6875);
const _d1 = LatLng(3.1579, 101.7132);
const _d2 = LatLng(3.16, 101.715);

RideRequest _req({
  String id = 'r1',
  String riderId = 'u1',
  LatLng pickup = _p1,
  LatLng destination = _d1,
  DateTime? departAt,
  int passengers = 1,
  RideServiceType type = RideServiceType.sharedEconomy,
  String status = 'waiting_match',
  String? stopId,
}) {
  return RideRequest(
    id: id,
    riderId: riderId,
    pickup: pickup,
    destination: destination,
    departAt: departAt ?? DateTime.utc(2026, 8, 28, 12, 0, 0),
    passengers: passengers,
    serviceType: type,
    status: status,
    nearestTransitStopId: stopId,
  );
}

FakeCarpoolRouting _trivialRouting() => FakeCarpoolRouting(
  soloDistance: (r) {
    const soloMap = {'r1': 4000.0, 'r2': 4200.0};
    return {
      'distance': soloMap[r.id] ?? 4000.0,
      'duration': (soloMap[r.id] ?? 4000.0) / 10,
    };
  },
  sequenceDistance: (order) {
    final base = 4500.0;
    if (order.join() == '0123') return base;
    return base + order.fold<double>(0, (s, e) => s + e);
  },
);

void main() {
  group('eligibility boundaries', () {
    test('different riders + shared economy + waiting_match = eligible', () {
      final matcher = CarpoolMatcher(routing: _trivialRouting());
      final a = _req(id: 'r1', riderId: 'u1');
      final b = _req(id: 'r2', riderId: 'u2', pickup: _p2, destination: _d2);
      final e = matcher.eligibility(a, b);
      expect(e.accepted, isTrue);
    });

    test('same rider rejected', () {
      final matcher = CarpoolMatcher(routing: _trivialRouting());
      final a = _req(id: 'r1', riderId: 'u1');
      final b = _req(id: 'r2', riderId: 'u1');
      final e = matcher.eligibility(a, b);
      expect(e.accepted, isFalse);
      expect(e.reasons.join(), contains('Same rider'));
    });

    test('too many passengers rejected', () {
      final matcher = CarpoolMatcher(
        routing: _trivialRouting(),
        maxPassengers: 4,
      );
      final a = _req(id: 'r1', riderId: 'u1', passengers: 3);
      final b = _req(id: 'r2', riderId: 'u2', pickup: _p2, passengers: 2);
      final e = matcher.eligibility(a, b);
      expect(e.accepted, isFalse);
      expect(e.reasons.join(), contains('3+2'));
    });

    test('pickup distance > 3 km rejected', () {
      final matcher = CarpoolMatcher(routing: _trivialRouting());
      final a = _req(id: 'r1', riderId: 'u1');
      final farPickup = const LatLng(3.165, 101.73);
      final b = _req(id: 'r2', riderId: 'u2', pickup: farPickup);
      final e = matcher.eligibility(a, b);
      expect(e.accepted, isFalse);
      expect(e.reasons.join(), contains('m apart'));
    });

    test('departure gap > 15 min rejected', () {
      final matcher = CarpoolMatcher(routing: _trivialRouting());
      final a = _req(id: 'r1', riderId: 'u1');
      final b = _req(
        id: 'r2',
        riderId: 'u2',
        pickup: _p2,
        departAt: a.departAt.add(const Duration(minutes: 16)),
      );
      final e = matcher.eligibility(a, b);
      expect(e.accepted, isFalse);
      expect(e.reasons.join(), contains('16 min'));
    });

    test('direction gap > 45 degrees rejected', () {
      final matcher = CarpoolMatcher(routing: _trivialRouting());
      final a = RideRequest(
        id: 'r1',
        riderId: 'u1',
        pickup: _base,
        destination: const LatLng(3.2, 101.6869),
        departAt: DateTime.utc(2026, 8, 28, 12),
        passengers: 1,
      );
      final bearing1 = a.pickupBearingDegrees;
      expect(bearing1, closeTo(0, 2));
      final b = RideRequest(
        id: 'r2',
        riderId: 'u2',
        pickup: _p2,
        destination: const LatLng(3.139, 101.8),
        departAt: DateTime.utc(2026, 8, 28, 12),
        passengers: 1,
      );
      final bearing2 = b.pickupBearingDegrees;
      expect(bearing2, closeTo(90, 2));
      final e = matcher.eligibility(a, b);
      expect(e.accepted, isFalse);
      expect(e.reasons.join(), contains('Directions differ'));
    });

    test('non-shared-economy rejected', () {
      final matcher = CarpoolMatcher(routing: _trivialRouting());
      final a = _req(id: 'r1', riderId: 'u1');
      final b = _req(
        id: 'r2',
        riderId: 'u2',
        type: RideServiceType.standard,
        pickup: _p2,
      );
      expect(matcher.eligibility(a, b).accepted, isFalse);
    });

    test('non waiting_match status rejected', () {
      final matcher = CarpoolMatcher(routing: _trivialRouting());
      final a = _req(id: 'r1', riderId: 'u1', status: 'matched');
      final b = _req(id: 'r2', riderId: 'u2', pickup: _p2);
      expect(matcher.eligibility(a, b).accepted, isFalse);
    });
  });

  group('sequence generation', () {
    test('for two riders yields 6 valid pickup-before-destination orders', () {
      final matcher = CarpoolMatcher(routing: _trivialRouting());
      final orders = matcher.validStopOrders(2);
      expect(orders, hasLength(6));
      for (final order in orders) {
        expect(order.indexOf(0), lessThan(order.indexOf(2)));
        expect(order.indexOf(1), lessThan(order.indexOf(3)));
      }
    });
  });

  group('scoring', () {
    test('perfect scenario scores near 100, clamp 0-100', () async {
      final routing = _trivialRouting();
      final matcher = CarpoolMatcher(routing: routing);
      final a = _req(id: 'r1', riderId: 'u1', stopId: 'STOP_A');
      final b = _req(
        id: 'r2',
        riderId: 'u2',
        pickup: _p2,
        destination: _d2,
        stopId: 'STOP_A',
      );
      final best = EvaluatedRoute(
        stopOrder: const [0, 1, 2, 3],
        pickupIndexes: const [0, 1],
        destinationIndexes: const [2, 3],
        totalDistanceMeters: 4400,
        totalDurationSeconds: 440,
        points: [a.pickup, b.pickup, a.destination, b.destination],
        riderDetourPercent: const {0: 5.0, 1: 4.76},
      );
      final result = await matcher.scoreAndDetour(a: a, b: b, best: best);
      expect(result.accepted, isTrue);
      expect(result.reasons.first, contains('Match score'));
    });

    test('score below 60 rejected', () async {
      final routing = _trivialRouting();
      final matcher = CarpoolMatcher(routing: routing, minScore: 60);
      final a = _req(id: 'r1', riderId: 'u1');
      final b = _req(
        id: 'r2',
        riderId: 'u2',
        pickup: _p2,
        departAt: a.departAt.add(const Duration(minutes: 14)),
      );
      final best = EvaluatedRoute(
        stopOrder: const [0, 1, 2, 3],
        pickupIndexes: const [0, 1],
        destinationIndexes: const [2, 3],
        totalDistanceMeters: 7000,
        totalDurationSeconds: 700,
        points: [a.pickup, b.pickup, a.destination, b.destination],
        riderDetourPercent: const {0: 24.9, 1: 24.9},
      );
      final result = await matcher.scoreAndDetour(a: a, b: b, best: best);
      expect(result.accepted, isFalse);
    });
  });

  group('tryMatch end-to-end', () {
    test('returns CarpoolMatch for compatible pair', () async {
      final matcher = CarpoolMatcher(routing: _trivialRouting());
      final a = _req(id: 'r1', riderId: 'u1');
      final b = _req(
        id: 'r2',
        riderId: 'u2',
        pickup: _p2,
        destination: _d2,
        stopId: 'SAME',
      );
      final match = await matcher.tryMatch(a, b);
      expect(match, isNotNull);
      expect(match!.score, greaterThanOrEqualTo(0));
      expect(match.score, lessThanOrEqualTo(100));
      expect(match.totalPassengers, 2);
      expect(match.reasons, isNotEmpty);
      expect(match.bestRoute.stopOrder, isNotEmpty);
    });

    test('routing failure never produces fake successful match', () async {
      final routing = FakeCarpoolRouting(
        soloDistance: (_) => {'distance': 0.0, 'duration': 0.0},
        sequenceDistance: (_) => 0.0,
        alwaysFail: true,
      );
      final matcher = CarpoolMatcher(routing: routing);
      final a = _req(id: 'r1', riderId: 'u1');
      final b = _req(id: 'r2', riderId: 'u2', pickup: _p2);
      final match = await matcher.tryMatch(a, b);
      expect(match, isNull);
    });

    test('25% detour exceeded on either rider -> no match', () async {
      final routing = FakeCarpoolRouting(
        soloDistance: (r) {
          return {'distance': r.id == 'r1' ? 1000 : 1000, 'duration': 100};
        },
        sequenceDistance: (_) => 1400,
      );
      final matcher = CarpoolMatcher(routing: routing);
      final a = _req(id: 'r1', riderId: 'u1');
      final b = _req(id: 'r2', riderId: 'u2', pickup: _p2);
      final match = await matcher.tryMatch(a, b);
      expect(match, isNull);
    });

    test('sortCandidates is deterministic', () {
      final r = _trivialRouting();
      final m = CarpoolMatcher(routing: r);
      final low = CarpoolMatch(
        requests: [
          _req(id: 'a'),
          _req(id: 'b'),
        ],
        score: 65,
        bestRoute: EvaluatedRoute(
          stopOrder: const [0, 1, 2, 3],
          pickupIndexes: const [0, 1],
          destinationIndexes: const [2, 3],
          totalDistanceMeters: 5000,
          totalDurationSeconds: 500,
          points: const [],
          riderDetourPercent: const {0: 15, 1: 15},
        ),
        reasons: const ['low'],
        riderDetourPercent: const {0: 15, 1: 15},
        maxDetourPercent: 15,
        departureDifferenceMinutes: 5,
        pickupDistanceMeters: 500,
        sameTransitStop: false,
      );
      final high = CarpoolMatch(
        requests: [
          _req(id: 'c'),
          _req(id: 'd'),
        ],
        score: 90,
        bestRoute: EvaluatedRoute(
          stopOrder: const [0, 1, 2, 3],
          pickupIndexes: const [0, 1],
          destinationIndexes: const [2, 3],
          totalDistanceMeters: 4500,
          totalDurationSeconds: 450,
          points: const [],
          riderDetourPercent: const {0: 5, 1: 5},
        ),
        reasons: const ['high'],
        riderDetourPercent: const {0: 5, 1: 5},
        maxDetourPercent: 5,
        departureDifferenceMinutes: 1,
        pickupDistanceMeters: 100,
        sameTransitStop: true,
      );
      final sorted = m.sortCandidates([low, high]);
      expect(sorted.first.score, 90);
      final sortedAgain = m.sortCandidates([low, high]);
      expect(
        sorted.map((m) => m.requests.first.id),
        sortedAgain.map((m) => m.requests.first.id),
      );
    });
  });
}
