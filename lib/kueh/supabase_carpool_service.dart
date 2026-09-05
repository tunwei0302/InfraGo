import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/kueh/carpool_matcher.dart';

class CarpoolServiceException implements Exception {
  const CarpoolServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Kueh-owned RPC-to-SQL mapping:
///
/// Contract name                | SQL migration name                | Owner
/// -----------------------------|-----------------------------------|-------
/// match_carpool_group (atomic) | create_carpool_match              | Kueh
/// accept_carpool_group         | accept_carpool_group              | Heng (driver claim)
/// cancel group membership      | cancel_carpool_group_membership   | Kueh
///
/// The SQL function `create_carpool_match` (in migration
/// 20260828000000_k_trip_planner.sql) is the authority for K4 atomic
/// match persistence. Both contract aliases refer to the same RPC.
class SupabaseCarpoolService {
  SupabaseCarpoolService({required this.client, required this.matcher});

  final SupabaseClient client;
  final CarpoolMatcher matcher;

  Future<List<CarpoolMatch>> findMatches(RideRequest request) async {
    try {
      final result = await client.rpc(
        'list_shared_ride_candidates',
        params: {'p_ride_id': request.id},
      );
      final rows = (result as List<dynamic>)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList(growable: false);
      final candidates = <RideRequest>[];
      for (final row in rows) {
        final parsed = _parseRequest(row);
        if (parsed != null) candidates.add(parsed);
      }
      return matcher.rankCandidates(request: request, candidates: candidates);
    } catch (error) {
      throw CarpoolServiceException('Unable to search shared rides: $error');
    }
  }

  Future<String> commitMatch(CarpoolMatch match) async {
    if (match.requests.length != 2) {
      throw const CarpoolServiceException('A match must contain two rides.');
    }
    final currentUid = client.auth.currentUser?.id;
    if (currentUid == null) {
      throw const CarpoolServiceException('Sign in to accept a shared match.');
    }

    // -----------------------------------------------------------------------
    // SQL RPC contract (see migration create_carpool_match L211-L213):
    //   auth.uid() MUST be v_a.rider_id OR v_b.rider_id (owner check).
    // Internally:
    //   stop_order[0] = rider A pickup, stop_order[1] = rider B pickup
    //   stop_order[2] = rider A dropoff, stop_order[3] = rider B dropoff
    //   p_detour_a / p_detour_b correspond to rider A / B respectively.
    //
    // If match.requests[0] is NOT the current user, swap A/B so p_ride_a
    // always points at the calling rider. Then remap stop_order indices and
    // swap detour values to preserve the same physical stop sequence.
    // -----------------------------------------------------------------------
    final a = match.requests[0];
    final b = match.requests[1];
    final aIsCaller = a.riderId == currentUid;
    final bIsCaller = b.riderId == currentUid;
    if (!aIsCaller && !bIsCaller) {
      throw const CarpoolServiceException(
        'You are not a participant of this shared match.',
      );
    }

    final rideA = aIsCaller ? a : b;
    final rideB = aIsCaller ? b : a;
    final detourA =
        (aIsCaller
            ? match.riderDetourPercent[0]
            : match.riderDetourPercent[1]) ??
        0;
    final detourB =
        (aIsCaller
            ? match.riderDetourPercent[1]
            : match.riderDetourPercent[0]) ??
        0;

    // stop_order remap when swapping caller from B → A:
    //   original A pickup idx 0 ↔ original B pickup idx 1
    //   original A dropoff idx 2 ↔ original B dropoff idx 3
    final originalStopOrder = match.bestRoute.stopOrder;
    final stopOrder = aIsCaller
        ? originalStopOrder
        : List<int>.from(
            originalStopOrder.map(
              (i) => const {0: 1, 1: 0, 2: 3, 3: 2}[i] ?? i,
            ),
          );

    try {
      final result = await client.rpc(
        'create_carpool_match',
        params: {
          'p_ride_a': rideA.id,
          'p_ride_b': rideB.id,
          'p_match_score': match.score,
          'p_match_reasons': match.reasons,
          'p_stop_order': stopOrder,
          'p_detour_a': detourA,
          'p_detour_b': detourB,
          'p_route_distance_meters': match.bestRoute.totalDistanceMeters,
          'p_route_duration_seconds': match.bestRoute.totalDurationSeconds,
          'p_vehicle_km_avoided': match.vehicleKmAvoidedMeters,
        },
      );
      final payload = Map<String, dynamic>.from(result as Map);
      if (payload['success'] != true) {
        throw CarpoolServiceException(
          'Match was rejected: ${payload['reason'] ?? 'unknown reason'}',
        );
      }
      return payload['group_id'] as String;
    } on CarpoolServiceException {
      rethrow;
    } catch (error) {
      throw CarpoolServiceException('Unable to save shared match: $error');
    }
  }

  RideRequest? _parseRequest(Map<String, dynamic> row) {
    try {
      final pickupLat = (row['pickup_latitude'] as num).toDouble();
      final pickupLng = (row['pickup_longitude'] as num).toDouble();
      final destinationLat = (row['destination_latitude'] as num).toDouble();
      final destinationLng = (row['destination_longitude'] as num).toDouble();
      return RideRequest(
        id: row['id'] as String,
        riderId: row['rider_id'] as String,
        pickup: LatLng(pickupLat, pickupLng),
        destination: LatLng(destinationLat, destinationLng),
        departAt: DateTime.parse(row['departure_time'] as String),
        passengers: (row['passenger_count'] as num).toInt(),
        status: 'waiting_match',
        serviceType: RideServiceType.sharedEconomy,
        nearestTransitStopId: row['transit_stop_id'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
