import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/shared/rpc_caller.dart';

class AdminReviewException implements Exception {
  const AdminReviewException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PendingIdentitySubmission {
  const PendingIdentitySubmission({
    required this.driverId,
    required this.driverName,
    required this.contact,
    required this.licencePath,
    required this.selfiePath,
    required this.submittedAt,
  });

  factory PendingIdentitySubmission.fromRow(Map<String, dynamic> row) {
    return PendingIdentitySubmission(
      driverId: row['driver_id'] as String,
      driverName: row['display_name']?.toString() ?? '(unknown)',
      contact: row['contact']?.toString() ?? '-',
      licencePath: row['licence_path']?.toString() ?? '',
      selfiePath: row['selfie_path']?.toString() ?? '',
      submittedAt: DateTime.tryParse(row['submitted_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  final String driverId;
  final String driverName;
  final String contact;
  final String licencePath;
  final String selfiePath;
  final DateTime submittedAt;
}

class PendingVehicleSubmission {
  const PendingVehicleSubmission({
    required this.driverId,
    required this.driverName,
    required this.make,
    required this.model,
    required this.color,
    required this.bodyType,
    required this.plateNumber,
    required this.passengerCapacity,
    required this.serviceEligibility,
  });

  factory PendingVehicleSubmission.fromRow(Map<String, dynamic> row) {
    final rawService = row['service_eligibility'];
    final List<String> service;
    if (rawService is List) {
      service = rawService.map((e) => e.toString()).toList(growable: false);
    } else {
      service = const [];
    }
    return PendingVehicleSubmission(
      driverId: row['driver_id'] as String,
      driverName: row['driver_name']?.toString() ?? '(unknown)',
      make: row['make']?.toString() ?? '-',
      model: row['model']?.toString() ?? '-',
      color: row['color']?.toString() ?? '-',
      bodyType: row['body_type']?.toString() ?? '-',
      plateNumber: row['plate_number']?.toString() ?? '-',
      passengerCapacity: (row['passenger_capacity'] as num?)?.toInt() ?? 0,
      serviceEligibility: service,
    );
  }

  final String driverId;
  final String driverName;
  final String make;
  final String model;
  final String color;
  final String bodyType;
  final String plateNumber;
  final int passengerCapacity;
  final List<String> serviceEligibility;

  bool get requestsSixSeater => serviceEligibility.contains('six_seater');
}

typedef AdminRowsLoader = Future<List<Map<String, dynamic>>> Function(
  String from, {
  required String statusColumn,
  required String statusValue,
  int? limit,
});

class AdminReviewRepository {
  AdminReviewRepository(
    SupabaseClient client, {
    RpcCaller? rpcCaller,
    AdminRowsLoader? loadRows,
  })  : _rpc = rpcCaller ?? client.rpc,
        _loadRows = loadRows ??
            ((from,
                {required statusColumn,
                required statusValue,
                limit}) async {
              dynamic query = client
                  .from(from)
                  .select()
                  .eq(statusColumn, statusValue);
              if (limit != null) query = query.limit(limit);
              return List<Map<String, dynamic>>.from(await query);
            });

  final RpcCaller _rpc;
  final AdminRowsLoader _loadRows;

  Future<List<PendingIdentitySubmission>> fetchPendingIdentities({
    int limit = 100,
  }) async {
    final rows = await _loadRows(
      'driver_verifications',
      statusColumn: 'approval_status',
      statusValue: 'pending',
      limit: limit,
    );
    return rows.map(PendingIdentitySubmission.fromRow).toList(growable: false);
  }

  Future<List<PendingVehicleSubmission>> fetchPendingVehicles({
    int limit = 100,
  }) async {
    final rows = await _loadRows(
      'driver_vehicles',
      statusColumn: 'approval_status',
      statusValue: 'pending',
      limit: limit,
    );
    return rows.map(PendingVehicleSubmission.fromRow).toList(growable: false);
  }

  Future<void> approveIdentity(String driverId) async {
    final result = await _rpc(
      'approve_driver_verification',
      params: {'p_driver_id': driverId},
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw AdminReviewException(
        map['reason']?.toString() ?? 'identity_approve_failed',
      );
    }
  }

  Future<void> rejectIdentity({
    required String driverId,
    required String reason,
  }) async {
    final result = await _rpc(
      'reject_driver_verification',
      params: {'p_driver_id': driverId, 'p_reason': reason},
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw AdminReviewException(
        map['reason']?.toString() ?? 'identity_reject_failed',
      );
    }
  }

  Future<void> approveVehicle(String driverId) async {
    final result = await _rpc(
      'approve_driver_vehicle',
      params: {'p_driver_id': driverId},
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      final reason = map['reason']?.toString() ?? 'vehicle_approve_failed';
      if (reason == 'six_seater_requires_capacity_6_plus') {
        final cap = map['submitted_capacity'];
        throw AdminReviewException(
          'Cannot approve 6-Seater service: submitted capacity is $cap '
          '(minimum 6 passengers required).',
        );
      }
      throw AdminReviewException(reason);
    }
  }

  Future<void> rejectVehicle({
    required String driverId,
    required String reason,
  }) async {
    final result = await _rpc(
      'reject_driver_vehicle',
      params: {'p_driver_id': driverId, 'p_reason': reason},
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw AdminReviewException(
        map['reason']?.toString() ?? 'vehicle_reject_failed',
      );
    }
  }

  Future<void> moderateRating({
    required String ratingId,
    required String action,
  }) async {
    final result = await _rpc(
      'admin_moderate_rating',
      params: {'p_rating_id': ratingId, 'p_action': action},
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw AdminReviewException(
        map['reason']?.toString() ?? 'moderation_failed',
      );
    }
  }
}
