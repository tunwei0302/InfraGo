import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/shared/rpc_caller.dart';

class SdgAnalyticsException implements Exception {
  const SdgAnalyticsException(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

class CapacityCount {
  const CapacityCount(this.capacity, this.count);
  final int capacity;
  final int count;
}

class ServiceCategoryCount {
  const ServiceCategoryCount(this.serviceType, this.count);
  final String serviceType;
  final int count;
}

class CancellationReasonCount {
  const CancellationReasonCount(this.reason, this.count);
  final String reason;
  final int count;
}

class PaymentAggregate {
  const PaymentAggregate({
    required this.method,
    required this.status,
    required this.count,
    required this.totalMYR,
  });

  final String method;
  final String status;
  final int count;
  final double totalMYR;
}

int _asInt(dynamic v) => (v as num?)?.toInt() ?? 0;
double _asDouble(dynamic v) => (v as num?)?.toDouble() ?? 0;
double? _asDoubleOrNull(dynamic v) => v == null ? null : (v as num).toDouble();

class SdgAnalyticsSnapshot {
  const SdgAnalyticsSnapshot({
    required this.completedRides,
    required this.transitLinkedRides,
    required this.sharedGroupsCompleted,
    required this.avgPassengersPerVehicle,
    required this.avgRiderDetourRatio,
    required this.estimatedSavingsMYR,
    required this.vehicleKmAvoided,
    required this.vehicleCapacityDistribution,
    required this.serviceCategoryDistribution,
    required this.cancelledCount,
    required this.completedCountForCancellation,
    required this.freeCancellationCount,
    required this.feeCancellationCount,
    required this.topCancellationReasons,
    required this.prototypeDriverCompensationMYR,
    required this.paymentAggregates,
  });

  static const empty = SdgAnalyticsSnapshot(
    completedRides: 0,
    transitLinkedRides: 0,
    sharedGroupsCompleted: 0,
    avgPassengersPerVehicle: null,
    avgRiderDetourRatio: null,
    estimatedSavingsMYR: 0,
    vehicleKmAvoided: 0,
    vehicleCapacityDistribution: [],
    serviceCategoryDistribution: [],
    cancelledCount: 0,
    completedCountForCancellation: 0,
    freeCancellationCount: 0,
    feeCancellationCount: 0,
    topCancellationReasons: [],
    prototypeDriverCompensationMYR: 0,
    paymentAggregates: [],
  );

  final int completedRides;
  final int transitLinkedRides;
  final int sharedGroupsCompleted;
  final double? avgPassengersPerVehicle;
  final double? avgRiderDetourRatio;
  final double estimatedSavingsMYR;
  final double vehicleKmAvoided;
  final List<CapacityCount> vehicleCapacityDistribution;
  final List<ServiceCategoryCount> serviceCategoryDistribution;
  final int cancelledCount;
  final int completedCountForCancellation;
  final int freeCancellationCount;
  final int feeCancellationCount;
  final List<CancellationReasonCount> topCancellationReasons;
  final double prototypeDriverCompensationMYR;
  final List<PaymentAggregate> paymentAggregates;

  double? get cancellationRate {
    final denom = cancelledCount + completedCountForCancellation;
    if (denom == 0) return null;
    return cancelledCount / denom;
  }

  factory SdgAnalyticsSnapshot.fromRpcResult(Map<String, dynamic> json) {
    final sdg = Map<String, dynamic>.from(json['sdg'] as Map? ?? const {});
    final cancellations = Map<String, dynamic>.from(
      json['cancellations'] as Map? ?? const {},
    );
    final capacityRaw =
        (json['vehicle_capacity_distribution'] as List?) ?? const [];
    final serviceRaw =
        (json['service_category_distribution'] as List?) ?? const [];
    final reasonsRaw = (cancellations['top_reasons'] as List?) ?? const [];
    final paymentsRaw = (json['payments'] as List?) ?? const [];

    return SdgAnalyticsSnapshot(
      completedRides: _asInt(sdg['completed_rides']),
      transitLinkedRides: _asInt(sdg['transit_linked_rides']),
      sharedGroupsCompleted: _asInt(sdg['shared_groups_completed']),
      avgPassengersPerVehicle: _asDoubleOrNull(
        sdg['avg_passengers_per_vehicle'],
      ),
      avgRiderDetourRatio: _asDoubleOrNull(sdg['avg_rider_detour_ratio']),
      estimatedSavingsMYR: _asDouble(sdg['estimated_savings_myr']),
      vehicleKmAvoided: _asDouble(sdg['vehicle_km_avoided']),
      vehicleCapacityDistribution: capacityRaw
          .map(
            (e) => CapacityCount(
              _asInt((e as Map)['capacity']),
              _asInt(e['count']),
            ),
          )
          .toList(growable: false),
      serviceCategoryDistribution: serviceRaw
          .map(
            (e) => ServiceCategoryCount(
              (e as Map)['service_type'].toString(),
              _asInt(e['count']),
            ),
          )
          .toList(growable: false),
      cancelledCount: _asInt(cancellations['cancelled_count']),
      completedCountForCancellation: _asInt(cancellations['completed_count']),
      freeCancellationCount: _asInt(cancellations['free_cancellation_count']),
      feeCancellationCount: _asInt(cancellations['fee_cancellation_count']),
      topCancellationReasons: reasonsRaw
          .map(
            (e) => CancellationReasonCount(
              (e as Map)['reason'].toString(),
              _asInt(e['count']),
            ),
          )
          .toList(growable: false),
      prototypeDriverCompensationMYR: _asDouble(
        cancellations['prototype_driver_compensation_myr'],
      ),
      paymentAggregates: paymentsRaw
          .map(
            (e) => PaymentAggregate(
              method: (e as Map)['method'].toString(),
              status: e['status'].toString(),
              count: _asInt(e['count']),
              totalMYR: _asDouble(e['total_myr']),
            ),
          )
          .toList(growable: false),
    );
  }
}

class SdgAnalyticsRepository {
  SdgAnalyticsRepository(SupabaseClient client, {RpcCaller? rpcCaller})
    : _rpc = rpcCaller ?? client.rpc;

  final RpcCaller _rpc;

  Future<SdgAnalyticsSnapshot> fetchSnapshot({
    DateTime? start,
    DateTime? end,
  }) async {
    if (start != null && end != null && start.isAfter(end)) {
      throw const SdgAnalyticsException('invalid_date_range');
    }
    dynamic result;
    try {
      result = await _rpc(
        'sdg_operational_analytics',
        params: {
          if (start != null) 'p_start': start.toUtc().toIso8601String(),
          if (end != null) 'p_end': end.toUtc().toIso8601String(),
        },
      );
    } catch (error) {
      throw SdgAnalyticsException('analytics_unavailable: $error');
    }
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw SdgAnalyticsException(
        map['reason']?.toString() ?? 'analytics_unavailable',
      );
    }
    return SdgAnalyticsSnapshot.fromRpcResult(map);
  }
}
