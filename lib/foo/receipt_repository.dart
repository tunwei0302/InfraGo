import 'package:supabase_flutter/supabase_flutter.dart';

class ReceiptFareQuote {
  const ReceiptFareQuote({
    required this.pricingVersion,
    required this.serviceType,
    required this.baseAmount,
    required this.vehicleMultiplier,
    required this.soloAmount,
    required this.sharedAmount,
    required this.currency,
    required this.quotedAt,
  });

  final String pricingVersion;
  final String serviceType;
  final double baseAmount;
  final double vehicleMultiplier;
  final double soloAmount;
  final double? sharedAmount;
  final String currency;
  final DateTime quotedAt;

  factory ReceiptFareQuote.fromJson(Map<String, dynamic> json) =>
      ReceiptFareQuote(
        pricingVersion: json['pricing_version'] as String,
        serviceType: json['service_type'] as String,
        baseAmount: (json['base_amount'] as num).toDouble(),
        vehicleMultiplier: (json['vehicle_multiplier'] as num).toDouble(),
        soloAmount: (json['solo_amount'] as num).toDouble(),
        sharedAmount: (json['shared_amount'] as num?)?.toDouble(),
        currency: json['currency'] as String,
        quotedAt: DateTime.parse(json['quoted_at'] as String),
      );
}

class ReceiptPayment {
  const ReceiptPayment({
    required this.method,
    required this.status,
    required this.quotedAmount,
    required this.discountAmount,
    required this.rewardPointsRedeemed,
    required this.cancellationFee,
    required this.refundedAmount,
    required this.finalAmount,
    required this.currency,
    required this.createdAt,
    required this.updatedAt,
  });

  final String method;
  final String status;
  final double quotedAmount;
  final double discountAmount;
  final int rewardPointsRedeemed;
  final double cancellationFee;
  final double refundedAmount;
  final double? finalAmount;
  final String currency;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ReceiptPayment.fromJson(Map<String, dynamic> json) => ReceiptPayment(
    method: json['method'] as String,
    status: json['status'] as String,
    quotedAmount: (json['quoted_amount'] as num).toDouble(),
    discountAmount: (json['discount_amount'] as num).toDouble(),
    rewardPointsRedeemed: (json['reward_points_redeemed'] as num).toInt(),
    cancellationFee: (json['cancellation_fee'] as num).toDouble(),
    refundedAmount: (json['refunded_amount'] as num).toDouble(),
    finalAmount: (json['final_amount'] as num?)?.toDouble(),
    currency: json['currency'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );
}

class ReceiptData {
  const ReceiptData({
    required this.rideId,
    this.driverId,
    required this.pickupLabel,
    required this.destinationLabel,
    required this.pickupLatitude,
    required this.pickupLongitude,
    required this.destinationLatitude,
    required this.destinationLongitude,
    required this.serviceType,
    required this.status,
    required this.departureTime,
    required this.routeDistanceMeters,
    required this.routeDurationSeconds,
    this.cancelledAt,
    this.cancellationReason,
    this.fareQuote,
    this.payment,
  });

  final String rideId;
  final String? driverId;
  final String pickupLabel;
  final String destinationLabel;
  final double? pickupLatitude;
  final double? pickupLongitude;
  final double? destinationLatitude;
  final double? destinationLongitude;
  final String serviceType;
  final String status;
  final DateTime departureTime;
  final double? routeDistanceMeters;
  final double? routeDurationSeconds;
  final DateTime? cancelledAt;
  final String? cancellationReason;
  final ReceiptFareQuote? fareQuote;
  final ReceiptPayment? payment;

  factory ReceiptData.fromJson(Map<String, dynamic> json) {
    final quotes = (json['fare_quotes'] as List?) ?? const [];
    final payments = (json['payments'] as List?) ?? const [];
    return ReceiptData(
      rideId: json['id'] as String,
      driverId: json['driver_id'] as String?,
      pickupLabel: json['pickup'] as String,
      destinationLabel: json['destination'] as String,
      pickupLatitude: (json['pickup_latitude'] as num?)?.toDouble(),
      pickupLongitude: (json['pickup_longitude'] as num?)?.toDouble(),
      destinationLatitude: (json['destination_latitude'] as num?)?.toDouble(),
      destinationLongitude: (json['destination_longitude'] as num?)?.toDouble(),
      serviceType: json['service_type'] as String,
      status: json['status'] as String,
      departureTime: DateTime.parse(json['departure_time'] as String),
      routeDistanceMeters: (json['route_distance_meters'] as num?)?.toDouble(),
      routeDurationSeconds: (json['route_duration_seconds'] as num?)?.toDouble(),
      cancelledAt: json['cancelled_at'] == null
          ? null
          : DateTime.parse(json['cancelled_at'] as String),
      cancellationReason: json['cancellation_reason'] as String?,
      fareQuote: quotes.isEmpty
          ? null
          : ReceiptFareQuote.fromJson(quotes.first as Map<String, dynamic>),
      payment: payments.isEmpty
          ? null
          : ReceiptPayment.fromJson(payments.first as Map<String, dynamic>),
    );
  }
}

class ReceiptRepository {
  const ReceiptRepository(this.client);

  final SupabaseClient client;

  Future<ReceiptData> loadReceipt(String rideId) async {
    final row = await client
        .from('rides')
        .select('*, fare_quotes(*), payments(*)')
        .eq('id', rideId)
        .order('quoted_at', referencedTable: 'fare_quotes', ascending: false)
        .order('created_at', referencedTable: 'payments', ascending: false)
        .single();
    return ReceiptData.fromJson(row);
  }

  Future<List<Map<String, dynamic>>> loadHistory(String riderId) async {
    final rows = await client
        .from('rides')
        .select()
        .eq('rider_id', riderId)
        .inFilter('status', ['completed', 'cancelled'])
        .order('departure_time', ascending: false);
    return List<Map<String, dynamic>>.from(rows as List);
  }

  Future<List<Map<String, dynamic>>> loadDriverHistory(String driverId) async {
    final rows = await client
        .from('rides')
        .select()
        .eq('driver_id', driverId)
        .inFilter('status', ['completed', 'cancelled'])
        .order('departure_time', ascending: false);
    return List<Map<String, dynamic>>.from(rows as List);
  }

  Future<bool> hasRating(String rideId) async {
    try {
      final rows = await client
          .from('driver_ratings')
          .select('id')
          .eq('ride_id', rideId)
          .limit(1);
      return (rows as List).isNotEmpty;
    } catch (_) {
      return true;
    }
  }
}
