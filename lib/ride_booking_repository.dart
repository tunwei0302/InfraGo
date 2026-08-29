import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'payment_method.dart';

class RideBookingException implements Exception {
  const RideBookingException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

class RideBookingResult {
  const RideBookingResult({
    required this.rideId,
    required this.paymentId,
    required this.status,
  });

  final String rideId;
  final String? paymentId;
  final String status;
}

class RideBookingRepository {
  const RideBookingRepository(this.client);

  final SupabaseClient client;

  Future<RideBookingResult> createRideWithQuoteAndPayment({
    required String pickupLabel,
    required String destinationLabel,
    required LatLng pickup,
    required LatLng destination,
    required String serviceType,
    required int passengerCount,
    required DateTime departureTime,
    required double routeDistanceMeters,
    required double routeDurationSeconds,
    required PaymentMethod paymentMethod,
    required String clientRequestId,
    String? pickupNote,
    String? transitStopId,
    String? transitStopName,
    int rewardPointsToRedeem = 0,
  }) async {
    Map<String, dynamic> map;
    try {
      final result = await client.rpc(
        'create_ride_with_quote_and_payment',
        params: {
          'p_pickup_label': pickupLabel,
          'p_destination_label': destinationLabel,
          'p_pickup_lat': pickup.latitude,
          'p_pickup_lng': pickup.longitude,
          'p_destination_lat': destination.latitude,
          'p_destination_lng': destination.longitude,
          'p_service_type': serviceType,
          'p_passenger_count': passengerCount,
          'p_departure_time': departureTime.toUtc().toIso8601String(),
          'p_route_distance_meters': routeDistanceMeters,
          'p_route_duration_seconds': routeDurationSeconds,
          'p_payment_method': paymentMethod.dbValue,
          'p_client_request_id': clientRequestId,
          'p_pickup_note': pickupNote,
          'p_transit_stop_id': transitStopId,
          'p_transit_stop_name': transitStopName,
          'p_reward_points_to_redeem': rewardPointsToRedeem,
        },
      );
      map = Map<String, dynamic>.from(result as Map);
    } catch (error) {
      throw RideBookingException('Could not create the ride: $error');
    }
    if (map['success'] != true) {
      throw RideBookingException(map['reason']?.toString() ?? 'booking_failed');
    }
    return RideBookingResult(
      rideId: map['ride_id'] as String,
      paymentId: map['payment_id']?.toString(),
      status: map['status']?.toString() ?? 'pending',
    );
  }
}
