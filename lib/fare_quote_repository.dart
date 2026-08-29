import 'package:supabase_flutter/supabase_flutter.dart';

import 'fare_estimator.dart';

class FareQuoteRepository {
  const FareQuoteRepository(this.client);

  final SupabaseClient client;

  Future<void> saveQuote({
    required String rideId,
    required FareQuote quote,
  }) async {
    await client.from('fare_quotes').insert({
      'ride_id': rideId,
      'pricing_version': quote.formulaVersion,
      'service_type': quote.serviceType.dbValue,
      'distance_meters': quote.distanceMeters,
      'duration_seconds': quote.durationSeconds,
      'base_amount': quote.baseAmount,
      'vehicle_multiplier': quote.vehicleMultiplier,
      'solo_amount': quote.soloAmount,
      'shared_amount': quote.sharedAmount,
      'currency': quote.currency,
      'quoted_at': quote.quotedAt.toUtc().toIso8601String(),
    });
  }
}
