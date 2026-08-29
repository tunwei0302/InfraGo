import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/kueh/carpool_matcher.dart';

class CarpoolServiceException implements Exception {
  const CarpoolServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SupabaseCarpoolService {
  SupabaseCarpoolService({required this.client, required this.matcher});

  final SupabaseClient client;
  final CarpoolMatcher matcher;

  Future<List<CarpoolMatch>> findMatches(RideRequest request) async {
    try {
      final rows = await client
          .from('rides')
          .select(
            'id,rider_id,status,service_type,passenger_count,departure_time,'
            'pickup_latitude,pickup_longitude,destination_latitude,'
            'destination_longitude,transit_stop_id',
          )
          .eq('service_type', 'shared_economy')
          .inFilter('status', ['waiting_match', 'requested'])
          .neq('id', request.id)
          .limit(20);
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
    try {
      final result = await client.rpc(
        'create_carpool_match',
        params: {
          'p_ride_a': match.requests[0].id,
          'p_ride_b': match.requests[1].id,
          'p_match_score': match.score,
          'p_match_reasons': match.reasons,
          'p_stop_order': match.bestRoute.stopOrder,
          'p_detour_a': match.riderDetourPercent[0] ?? 0,
          'p_detour_b': match.riderDetourPercent[1] ?? 0,
          'p_route_distance_meters': match.bestRoute.totalDistanceMeters,
          'p_route_duration_seconds': match.bestRoute.totalDurationSeconds,
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
