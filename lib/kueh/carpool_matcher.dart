import 'dart:math';

import 'package:latlong2/latlong.dart';

import 'package:infra_go/kueh/osrm_routing_service.dart';

enum RideServiceType { standard, sharedEconomy }

class RideRequest {
  const RideRequest({
    required this.id,
    required this.riderId,
    required this.pickup,
    required this.destination,
    required this.departAt,
    required this.passengers,
    this.serviceType = RideServiceType.sharedEconomy,
    this.status = 'waiting_match',
    this.nearestTransitStopId,
  });

  final String id;
  final String riderId;
  final LatLng pickup;
  final LatLng destination;
  final DateTime departAt;
  final int passengers;
  final RideServiceType serviceType;
  final String status;
  final String? nearestTransitStopId;

  double get pickupBearingDegrees => bearingBetween(pickup, destination);
}

class MatchExplanation {
  const MatchExplanation({required this.accepted, required this.reasons});

  final bool accepted;
  final List<String> reasons;
}

class EvaluatedRoute {
  const EvaluatedRoute({
    required this.stopOrder,
    required this.pickupIndexes,
    required this.destinationIndexes,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    required this.points,
    required this.riderDetourPercent,
  });

  final List<int> stopOrder;
  final List<int> pickupIndexes;
  final List<int> destinationIndexes;
  final double totalDistanceMeters;
  final double totalDurationSeconds;
  final List<LatLng> points;
  final Map<int, double> riderDetourPercent;
}

class CarpoolMatch {
  const CarpoolMatch({
    required this.requests,
    required this.score,
    required this.bestRoute,
    required this.reasons,
    required this.riderDetourPercent,
    required this.maxDetourPercent,
    required this.departureDifferenceMinutes,
    required this.pickupDistanceMeters,
    required this.sameTransitStop,
    this.soloTotalDistanceMeters = 0,
    this.vehicleKmAvoidedMeters = 0,
  });

  final List<RideRequest> requests;
  final int score;
  final EvaluatedRoute bestRoute;
  final List<String> reasons;
  final Map<int, double> riderDetourPercent;
  final double maxDetourPercent;
  final int departureDifferenceMinutes;
  final double pickupDistanceMeters;
  final bool sameTransitStop;
  final double soloTotalDistanceMeters;
  final double vehicleKmAvoidedMeters;

  int get totalPassengers => requests.fold<int>(0, (s, r) => s + r.passengers);
}

abstract class CarpoolRoutingProvider {
  Future<Map<String, double>> soloDistanceSeconds(RideRequest r);
  Future<EvaluatedRoute?> evaluateStopSequence({
    required List<RideRequest> requests,
    required List<int> stopOrder,
    required List<int> pickupIndexes,
    required List<int> destinationIndexes,
  });
}

class _CarpoolDefaults {
  static const maxPassengers = 4;
  static const double maxPickupDistanceMeters = 3000;
  static const maxDepartureDiffMinutes = 15;
  static const double maxDirectionDiffDegrees = 45;
  static const double maxDetourPercent = 25;
  static const minScore = 60;
}

class CarpoolMatcher {
  CarpoolMatcher({
    required this.routing,
    this.maxPassengers = _CarpoolDefaults.maxPassengers,
    this.maxPickupDistanceMeters = _CarpoolDefaults.maxPickupDistanceMeters,
    this.maxDepartureDiffMinutes = _CarpoolDefaults.maxDepartureDiffMinutes,
    this.maxDirectionDiffDegrees = _CarpoolDefaults.maxDirectionDiffDegrees,
    this.maxDetourPercent = _CarpoolDefaults.maxDetourPercent,
    this.minScore = _CarpoolDefaults.minScore,
  });

  final CarpoolRoutingProvider routing;
  final int maxPassengers;
  final double maxPickupDistanceMeters;
  final int maxDepartureDiffMinutes;
  final double maxDirectionDiffDegrees;
  final double maxDetourPercent;
  final int minScore;

  MatchExplanation eligibility(RideRequest a, RideRequest b) {
    final reasons = <String>[];
    if (a.id == b.id) {
      reasons.add('Same ride id cannot be matched with itself.');
    }
    if (a.riderId == b.riderId) {
      reasons.add('Same rider orders are never matched together.');
    }
    if (a.serviceType != RideServiceType.sharedEconomy) {
      reasons.add('Rider A service type is not shared economy.');
    }
    if (b.serviceType != RideServiceType.sharedEconomy) {
      reasons.add('Rider B service type is not shared economy.');
    }
    if (a.status != 'waiting_match') {
      reasons.add('Rider A status is ${a.status}; expected waiting_match.');
    }
    if (b.status != 'waiting_match') {
      reasons.add('Rider B status is ${b.status}; expected waiting_match.');
    }
    if (a.passengers + b.passengers > maxPassengers) {
      reasons.add(
        'Combined passengers ${a.passengers}+${b.passengers} exceeds '
        'limit of $maxPassengers.',
      );
    }
    final pickupDist = haversineMeters(a.pickup, b.pickup);
    if (pickupDist > maxPickupDistanceMeters) {
      reasons.add(
        'Pickups are ${pickupDist.round()} m apart; limit is '
        '${maxPickupDistanceMeters.round()} m.',
      );
    }
    final departDiff = a.departAt.difference(b.departAt).abs().inMinutes;
    if (departDiff > maxDepartureDiffMinutes) {
      reasons.add(
        'Departures differ by $departDiff min; limit is '
        '$maxDepartureDiffMinutes min.',
      );
    }
    final dirDiff = directionDifferenceDegrees(
      a.pickupBearingDegrees,
      b.pickupBearingDegrees,
    );
    if (dirDiff > maxDirectionDiffDegrees) {
      reasons.add(
        'Directions differ by ${dirDiff.toStringAsFixed(0)}°; limit is '
        '${maxDirectionDiffDegrees.toStringAsFixed(0)}°.',
      );
    }
    if (reasons.isNotEmpty) {
      return MatchExplanation(accepted: false, reasons: reasons);
    }
    return MatchExplanation(
      accepted: true,
      reasons: [
        'Different riders, both shared economy, waiting for match.',
        'Combined ${a.passengers}+${b.passengers} passengers within limit.',
        'Pickups ${pickupDist.round()} m apart (≤ '
            '${maxPickupDistanceMeters.round()} m).',
        'Departure gap $departDiff min (≤ $maxDepartureDiffMinutes min).',
        'Direction gap ${dirDiff.toStringAsFixed(0)}° (≤ '
            '${maxDirectionDiffDegrees.toStringAsFixed(0)}°).',
      ],
    );
  }

  List<List<int>> validStopOrders(int riderCount) {
    if (riderCount != 2) {
      throw ArgumentError('Only two-rider groups are supported.');
    }
    const d = [2, 3];
    final orders = <List<int>>[];
    void permute(List<int> current, Set<int> used) {
      if (current.length == 4) {
        orders.add(List.of(current));
        return;
      }
      for (var i = 0; i < 4; i++) {
        if (used.contains(i)) continue;
        if (d.contains(i) && !used.contains(i - 2)) continue;
        used.add(i);
        current.add(i);
        permute(current, used);
        current.removeLast();
        used.remove(i);
      }
    }

    permute(<int>[], <int>{});
    return orders;
  }

  Future<MatchExplanation> scoreAndDetour({
    required RideRequest a,
    required RideRequest b,
    required EvaluatedRoute best,
    Map<int, double>? soloDistanceMeters,
  }) async {
    final soloDistA =
        soloDistanceMeters?[0] ??
        (await routing.soloDistanceSeconds(a))['distance']!;
    final soloDistB =
        soloDistanceMeters?[1] ??
        (await routing.soloDistanceSeconds(b))['distance']!;
    final detourA = best.riderDetourPercent[0] ?? 0;
    final detourB = best.riderDetourPercent[1] ?? 0;
    final maxDetour = max(detourA, detourB);
    final reasons = <String>[];

    if (detourA > maxDetourPercent) {
      reasons.add(
        'Rider A detour ${detourA.toStringAsFixed(1)}% exceeds '
        '${maxDetourPercent.toStringAsFixed(0)}%.',
      );
    }
    if (detourB > maxDetourPercent) {
      reasons.add(
        'Rider B detour ${detourB.toStringAsFixed(1)}% exceeds '
        '${maxDetourPercent.toStringAsFixed(0)}%.',
      );
    }

    final departDiff = a.departAt.difference(b.departAt).abs().inMinutes;
    final pickupDist = haversineMeters(a.pickup, b.pickup);
    final sameStop =
        a.nearestTransitStopId != null &&
        b.nearestTransitStopId != null &&
        a.nearestTransitStopId == b.nearestTransitStopId;

    double score = 100;
    score -= 40 * (maxDetour / maxDetourPercent);
    score -= 30 * (departDiff / maxDepartureDiffMinutes);
    score -= 20 * (pickupDist / maxPickupDistanceMeters);
    if (sameStop) score += 10;
    if (score < 0) score = 0;
    if (score > 100) score = 100;
    final rounded = score.round();

    if (rounded < minScore) {
      reasons.add('Score $rounded is below minimum $minScore.');
    }
    if (reasons.isNotEmpty) {
      return MatchExplanation(
        accepted: false,
        reasons: [
          'Match score $rounded/100 (max detour '
              '${maxDetour.toStringAsFixed(1)}%, '
              'time gap ${departDiff}min, pickup gap '
              '${pickupDist.round()}m, same stop: $sameStop).',
          ...reasons,
        ],
      );
    }

    return MatchExplanation(
      accepted: true,
      reasons: [
        'Match score $rounded/100.',
        'Rider A solo ${(soloDistA / 1000).toStringAsFixed(1)} km → shared '
            '${detourA.toStringAsFixed(1)}% detour.',
        'Rider B solo ${(soloDistB / 1000).toStringAsFixed(1)} km → shared '
            '${detourB.toStringAsFixed(1)}% detour.',
        if (sameStop) 'Both board at the same transit stop.',
      ],
    );
  }

  Future<CarpoolMatch?> tryMatch(RideRequest a, RideRequest b) async {
    final eligible = eligibility(a, b);
    if (!eligible.accepted) return null;

    final requests = [a, b];
    final orders = validStopOrders(2);
    EvaluatedRoute? best;
    final failures = <String>[];
    for (final order in orders) {
      final pickupIndexes = <int>[];
      final destIndexes = <int>[];
      for (var i = 0; i < order.length; i++) {
        if (order[i] < 2) {
          pickupIndexes.add(i);
        } else {
          destIndexes.add(i);
        }
      }
      EvaluatedRoute? evaluated;
      try {
        evaluated = await routing.evaluateStopSequence(
          requests: requests,
          stopOrder: order,
          pickupIndexes: pickupIndexes,
          destinationIndexes: destIndexes,
        );
      } catch (e) {
        failures.add('seq_${order.join('')}: $e');
        continue;
      }
      if (evaluated == null) continue;
      if (best == null ||
          evaluated.totalDistanceMeters < best.totalDistanceMeters) {
        best = evaluated;
      }
    }
    if (best == null) {
      if (failures.isNotEmpty) {
        return null;
      }
      return null;
    }

    final soloDistanceMeters = <int, double>{
      0: (await routing.soloDistanceSeconds(a))['distance']!,
      1: (await routing.soloDistanceSeconds(b))['distance']!,
    };
    final scoreExplanation = await scoreAndDetour(
      a: a,
      b: b,
      best: best,
      soloDistanceMeters: soloDistanceMeters,
    );
    if (!scoreExplanation.accepted) return null;

    final departDiff = a.departAt.difference(b.departAt).abs().inMinutes;
    final pickupDist = haversineMeters(a.pickup, b.pickup);
    final sameStop =
        a.nearestTransitStopId != null &&
        b.nearestTransitStopId != null &&
        a.nearestTransitStopId == b.nearestTransitStopId;
    final maxDetour = max<double>(
      best.riderDetourPercent[0] ?? 0,
      best.riderDetourPercent[1] ?? 0,
    );
    final soloTotalDistanceMeters =
        soloDistanceMeters[0]! + soloDistanceMeters[1]!;
    final vehicleKmAvoidedMeters = max<double>(
      0,
      soloTotalDistanceMeters - best.totalDistanceMeters,
    );

    return CarpoolMatch(
      requests: requests,
      score: _computeScore(
        maxDetourPercent: maxDetour,
        departureDifferenceMinutes: departDiff,
        pickupDistanceMeters: pickupDist,
        sameTransitStop: sameStop,
      ),
      bestRoute: best,
      reasons: scoreExplanation.reasons,
      riderDetourPercent: best.riderDetourPercent,
      maxDetourPercent: maxDetour,
      departureDifferenceMinutes: departDiff,
      pickupDistanceMeters: pickupDist,
      sameTransitStop: sameStop,
      soloTotalDistanceMeters: soloTotalDistanceMeters,
      vehicleKmAvoidedMeters: vehicleKmAvoidedMeters,
    );
  }

  Future<List<CarpoolMatch>> rankCandidates({
    required RideRequest request,
    required Iterable<RideRequest> candidates,
  }) async {
    final matches = <CarpoolMatch>[];
    for (final candidate in candidates) {
      final match = await tryMatch(request, candidate);
      if (match != null) matches.add(match);
    }
    return sortCandidates(matches);
  }

  List<CarpoolMatch> sortCandidates(List<CarpoolMatch> candidates) {
    final out = List.of(candidates);
    out.sort((a, b) {
      final s = b.score.compareTo(a.score);
      if (s != 0) return s;
      final d = a.maxDetourPercent.compareTo(b.maxDetourPercent);
      if (d != 0) return d;
      final t = a.departureDifferenceMinutes.compareTo(
        b.departureDifferenceMinutes,
      );
      if (t != 0) return t;
      final p = a.pickupDistanceMeters.compareTo(b.pickupDistanceMeters);
      if (p != 0) return p;
      return a.requests.first.id.compareTo(b.requests.first.id);
    });
    return out;
  }

  int _computeScore({
    required double maxDetourPercent,
    required int departureDifferenceMinutes,
    required double pickupDistanceMeters,
    required bool sameTransitStop,
  }) {
    double s = 100;
    s -= 40 * (maxDetourPercent / this.maxDetourPercent);
    s -= 30 * (departureDifferenceMinutes / maxDepartureDiffMinutes);
    s -= 20 * (pickupDistanceMeters / maxPickupDistanceMeters);
    if (sameTransitStop) s += 10;
    if (s < 0) s = 0;
    if (s > 100) s = 100;
    return s.round();
  }
}

class OsrmCarpoolRouting implements CarpoolRoutingProvider {
  OsrmCarpoolRouting(this.osrm);

  final OsrmRoutingService osrm;

  @override
  Future<Map<String, double>> soloDistanceSeconds(RideRequest request) async {
    final route = await osrm.route(request.pickup, request.destination);
    return {
      'distance': route.distanceMeters,
      'duration': route.durationSeconds,
    };
  }

  @override
  Future<EvaluatedRoute?> evaluateStopSequence({
    required List<RideRequest> requests,
    required List<int> stopOrder,
    required List<int> pickupIndexes,
    required List<int> destinationIndexes,
  }) async {
    if (requests.length != 2 || stopOrder.length != 4) return null;
    final stops = <LatLng>[
      requests[0].pickup,
      requests[1].pickup,
      requests[0].destination,
      requests[1].destination,
    ];
    final route = await osrm.multiStopRoute(stops, preferredOrder: stopOrder);
    final detours = <int, double>{};
    for (var rider = 0; rider < requests.length; rider++) {
      final pickupPosition = stopOrder.indexOf(rider);
      final destinationPosition = stopOrder.indexOf(rider + requests.length);
      if (pickupPosition < 0 || destinationPosition <= pickupPosition) {
        return null;
      }
      var sharedDistance = 0.0;
      for (var leg = pickupPosition; leg < destinationPosition; leg++) {
        sharedDistance += route.legDistanceMeters[leg];
      }
      final solo = await soloDistanceSeconds(requests[rider]);
      final soloDistance = solo['distance'] ?? 0;
      if (soloDistance <= 0) return null;
      detours[rider] = max(
        0.0,
        ((sharedDistance - soloDistance) / soloDistance) * 100,
      );
    }
    return EvaluatedRoute(
      stopOrder: stopOrder,
      pickupIndexes: pickupIndexes,
      destinationIndexes: destinationIndexes,
      totalDistanceMeters: route.totalDistanceMeters,
      totalDurationSeconds: route.totalDurationSeconds,
      points: route.points,
      riderDetourPercent: detours,
    );
  }
}

class FakeCarpoolRouting implements CarpoolRoutingProvider {
  FakeCarpoolRouting({
    required this.soloDistance,
    required this.sequenceDistance,
    this.alwaysFail = false,
  });

  final Map<String, double> Function(RideRequest) soloDistance;
  final double Function(List<int> stopOrder) sequenceDistance;
  final bool alwaysFail;

  @override
  Future<Map<String, double>> soloDistanceSeconds(RideRequest r) async {
    if (alwaysFail) throw Exception('routing unavailable');
    return soloDistance(r);
  }

  @override
  Future<EvaluatedRoute?> evaluateStopSequence({
    required List<RideRequest> requests,
    required List<int> stopOrder,
    required List<int> pickupIndexes,
    required List<int> destinationIndexes,
  }) async {
    if (alwaysFail) throw Exception('routing unavailable');
    final dist = sequenceDistance(stopOrder);
    final soloA = soloDistance(requests[0])['distance']!;
    final soloB = soloDistance(requests[1])['distance']!;
    final detourA = max(0.0, ((dist - soloA) / soloA) * 100);
    final detourB = max(0.0, ((dist - soloB) / soloB) * 100);
    final stops = [
      requests[0].pickup,
      requests[1].pickup,
      requests[0].destination,
      requests[1].destination,
    ];
    return EvaluatedRoute(
      stopOrder: stopOrder,
      pickupIndexes: pickupIndexes,
      destinationIndexes: destinationIndexes,
      totalDistanceMeters: dist,
      totalDurationSeconds: dist / 10,
      points: stopOrder.map((i) => stops[i]).toList(growable: false),
      riderDetourPercent: {0: detourA, 1: detourB},
    );
  }
}

class AtomicGroupJoinResult {
  const AtomicGroupJoinResult({
    required this.success,
    this.groupId,
    this.reason,
  });

  final bool success;
  final String? groupId;
  final String? reason;
}

abstract class GroupRpcClient {
  Future<AtomicGroupJoinResult> createOrJoin({
    required String rideId,
    required int capacity,
    String? groupIdToJoin,
    required int ridersInGroup,
  });
}
