import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/heng/driver_models.dart';

class DriverRepository {
  DriverRepository(this._client);

  final SupabaseClient _client;

  String get _driverId {
    final id = _client.auth.currentUser?.id;
    if (id == null) throw StateError('Sign in as a driver first.');
    return id;
  }

  Future<DriverReadiness> loadReadiness() async {
    final result = await _client.rpc('get_my_driver_readiness');
    final data = Map<String, dynamic>.from(result as Map);
    final vehicleData = data['vehicle'];
    return DriverReadiness(
      verificationStatus: approvalStatusFrom(data['verification_status']),
      vehicleStatus: approvalStatusFrom(data['vehicle_status']),
      rejectionReason: data['rejection_reason']?.toString(),
      vehicle: vehicleData is Map
          ? DriverVehicle.fromJson(Map<String, dynamic>.from(vehicleData))
          : null,
    );
  }

  Future<String> _uploadPrivateImage({
    required String kind,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final extension = fileName.toLowerCase().split('.').last;
    final contentType = extension == 'png' ? 'image/png' : 'image/jpeg';
    final path =
        '$_driverId/${kind}_${DateTime.now().millisecondsSinceEpoch}.$extension';
    await _client.storage
        .from('driver-documents')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: false),
        );
    return path;
  }

  Future<void> submitOnboarding({
    required String displayName,
    required String contact,
    required Uint8List licenceBytes,
    required String licenceName,
    required Uint8List selfieBytes,
    required String selfieName,
    required String make,
    required String model,
    required String color,
    required String bodyType,
    required String plateNumber,
    required int passengerCapacity,
  }) async {
    final licencePath = await _uploadPrivateImage(
      kind: 'licence',
      fileName: licenceName,
      bytes: licenceBytes,
    );
    final selfiePath = await _uploadPrivateImage(
      kind: 'selfie',
      fileName: selfieName,
      bytes: selfieBytes,
    );
    await _client.rpc(
      'submit_driver_onboarding',
      params: {
        'p_display_name': displayName.trim(),
        'p_contact': contact.trim(),
        'p_licence_path': licencePath,
        'p_selfie_path': selfiePath,
        'p_make': make.trim(),
        'p_model': model.trim(),
        'p_color': color.trim(),
        'p_body_type': bodyType,
        'p_plate_number': DriverOnboardingValidator.normalisePlate(plateNumber),
        'p_passenger_capacity': passengerCapacity,
      },
    );
  }

  Future<Map<String, dynamic>> acceptRide(String rideId) async {
    final result = await _client.rpc(
      'accept_available_ride',
      params: {'p_ride_id': rideId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> acceptGroup(String groupId) async {
    final result = await _client.rpc(
      'accept_carpool_group',
      params: {'p_group_id': groupId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> transitionRide(
    String rideId,
    String nextStatus, {
    String? cancellationReason,
  }) async {
    final result = await _client.rpc(
      'transition_driver_ride',
      params: {
        'p_ride_id': rideId,
        'p_next_status': nextStatus,
        'p_cancellation_reason': cancellationReason,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<void> setOffline() async {
    await _client.rpc('set_my_driver_offline');
  }
}
