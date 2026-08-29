import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'trip_planner_state.dart';

class RideDraft {
  const RideDraft({
    required this.riderId,
    required this.pickupLabel,
    required this.destinationLabel,
    required this.pickup,
    required this.destination,
    required this.serviceType,
    required this.passengerCount,
    required this.departureTime,
    required this.routeDistanceMeters,
    required this.routeDurationSeconds,
    this.pickupNote,
    this.transitStopId,
    this.transitStopName,
    this.estimatedSoloFare,
    this.estimatedSharedFare,
  });

  final String riderId;
  final String pickupLabel;
  final String destinationLabel;
  final LatLng pickup;
  final LatLng destination;
  final String serviceType;
  final int passengerCount;
  final DateTime departureTime;
  final double routeDistanceMeters;
  final double routeDurationSeconds;
  final String? pickupNote;
  final String? transitStopId;
  final String? transitStopName;
  final double? estimatedSoloFare;
  final double? estimatedSharedFare;

  Map<String, dynamic> toJson() => {
    'rider_id': riderId,
    'pickup': pickupLabel,
    'destination': destinationLabel,
    'pickup_latitude': pickup.latitude,
    'pickup_longitude': pickup.longitude,
    'destination_latitude': destination.latitude,
    'destination_longitude': destination.longitude,
    'status': serviceType == 'shared_economy' ? 'waiting_match' : 'requested',
    'service_type': serviceType,
    'passenger_count': passengerCount,
    'departure_time': departureTime.toUtc().toIso8601String(),
    'route_distance_meters': routeDistanceMeters,
    'route_duration_seconds': routeDurationSeconds,
    if (pickupNote != null) 'pickup_note': pickupNote,
    if (transitStopId != null) 'transit_stop_id': transitStopId,
    if (transitStopName != null) 'transit_stop_name': transitStopName,
    if (estimatedSoloFare != null) 'estimated_solo_fare': estimatedSoloFare,
    if (estimatedSharedFare != null)
      'estimated_shared_fare': estimatedSharedFare,
  };
}

class RideLifecycleSnapshot {
  const RideLifecycleSnapshot({
    required this.id,
    required this.status,
    this.driverId,
  });

  final String id;
  final String status;
  final String? driverId;

  factory RideLifecycleSnapshot.fromJson(Map<String, dynamic> json) =>
      RideLifecycleSnapshot(
        id: json['id'] as String,
        status: json['status'] as String? ?? 'requested',
        driverId: json['driver_id'] as String?,
      );
}

class TripPlannerRepositoryException implements Exception {
  const TripPlannerRepositoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class TripPlannerRepository {
  Future<String> createRide(RideDraft draft);

  Stream<RideLifecycleSnapshot> watchRide(String rideId);

  Future<AssignedDriverInfo> loadAssignedDriver(String driverId);

  Future<void> cancelRide(String rideId, {required String reason});
}

class SupabaseTripPlannerRepository implements TripPlannerRepository {
  SupabaseTripPlannerRepository(this.client);

  final SupabaseClient client;

  @override
  Future<String> createRide(RideDraft draft) async {
    try {
      final row = await client
          .from('rides')
          .insert(draft.toJson())
          .select('id')
          .single();
      return row['id'] as String;
    } catch (error) {
      throw TripPlannerRepositoryException(
        'The ride could not be created. Check that the latest database '
        'migration is installed. Details: $error',
      );
    }
  }

  @override
  Stream<RideLifecycleSnapshot> watchRide(String rideId) => client
      .from('rides')
      .stream(primaryKey: ['id'])
      .eq('id', rideId)
      .map(
        (rows) => rows.isEmpty
            ? throw const TripPlannerRepositoryException('Ride was not found.')
            : RideLifecycleSnapshot.fromJson(rows.first),
      );

  @override
  Future<AssignedDriverInfo> loadAssignedDriver(String driverId) async {
    Map<String, dynamic>? publicDriver;
    try {
      publicDriver = await client
          .from('driver_public_profiles')
          .select()
          .eq('driver_id', driverId)
          .maybeSingle();
    } catch (_) {
      publicDriver = null;
    }

    Map<String, dynamic>? profile;
    if (publicDriver == null) {
      try {
        profile = await client
            .from('profiles')
            .select('name')
            .eq('id', driverId)
            .maybeSingle();
      } catch (_) {
        profile = null;
      }
    }

    final row = publicDriver ?? const <String, dynamic>{};
    return AssignedDriverInfo(
      driverId: driverId,
      name: (row['name'] ?? profile?['name'] ?? 'Assigned driver').toString(),
      rating: (row['rating'] as num?)?.toDouble() ?? 0,
      vehicleMake: (row['vehicle_make'] ?? 'Registered').toString(),
      vehicleModel: (row['vehicle_model'] ?? 'vehicle').toString(),
      vehiclePlate: (row['plate_number'] ?? 'Details pending').toString(),
      vehicleColor: (row['vehicle_color'] ?? '').toString(),
      etaMinutes: (row['eta_minutes'] as num?)?.toInt() ?? 0,
      phoneLastFour: row['phone_last_four'] as String?,
    );
  }

  @override
  Future<void> cancelRide(String rideId, {required String reason}) async {
    try {
      try {
        await client.rpc(
          'cancel_carpool_group_membership',
          params: {'p_ride_id': rideId},
        );
      } catch (_) {}
      await client
          .from('rides')
          .update({
            'status': 'cancelled',
            'cancelled_at': DateTime.now().toUtc().toIso8601String(),
            'cancellation_reason': reason,
          })
          .eq('id', rideId);
    } catch (error) {
      throw TripPlannerRepositoryException('Unable to cancel ride: $error');
    }
  }
}
