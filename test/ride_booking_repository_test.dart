import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/payment_method.dart';
import 'package:infra_go/ride_booking_repository.dart';

SupabaseClient _dummyClient() =>
    SupabaseClient('https://example.supabase.co', 'test-anon-key');

RideBookingRepository _repoReturning(Map<String, dynamic> response) {
  return RideBookingRepository(
    _dummyClient(),
    rpcCaller: (fn, {params}) async => response,
  );
}

void main() {
  final pickup = const LatLng(3.1390, 101.6869);
  final destination = const LatLng(3.1580, 101.7113);

  Future<RideBookingResult> book(
    RideBookingRepository repo, {
    int rewardPointsToRedeem = 0,
  }) {
    return repo.createRideWithQuoteAndPayment(
      pickupLabel: 'Home',
      destinationLabel: 'Office',
      pickup: pickup,
      destination: destination,
      serviceType: 'economy_4',
      passengerCount: 1,
      departureTime: DateTime.utc(2026, 8, 29, 12),
      routeDistanceMeters: 5000,
      routeDurationSeconds: 600,
      paymentMethod: PaymentMethod.cash,
      clientRequestId: 'req-1',
      rewardPointsToRedeem: rewardPointsToRedeem,
    );
  }

  test('a successful booking returns the ride/payment identifiers', () async {
    final repo = _repoReturning({
      'success': true,
      'ride_id': 'ride-1',
      'payment_id': 'payment-1',
      'status': 'pending',
    });
    final result = await book(repo);
    expect(result.rideId, 'ride-1');
    expect(result.paymentId, 'payment-1');
    expect(result.status, 'pending');
  });

  test('sends the RPC parameters the SQL function expects', () async {
    late String calledFn;
    late Map<String, dynamic>? calledParams;
    final repo = RideBookingRepository(
      _dummyClient(),
      rpcCaller: (fn, {params}) async {
        calledFn = fn;
        calledParams = params;
        return {'success': true, 'ride_id': 'ride-1', 'status': 'pending'};
      },
    );
    await book(repo, rewardPointsToRedeem: 150);
    expect(calledFn, 'create_ride_with_quote_and_payment');
    expect(calledParams!['p_service_type'], 'economy_4');
    expect(calledParams!['p_payment_method'], 'cash');
    expect(calledParams!['p_client_request_id'], 'req-1');
    expect(calledParams!['p_reward_points_to_redeem'], 150);
    expect(calledParams!['p_pickup_lat'], pickup.latitude);
    expect(calledParams!['p_destination_lng'], destination.longitude);
  });

  test('a friendly RPC failure surfaces its reason', () async {
    final repo = _repoReturning({
      'success': false,
      'reason': 'reward_redemption_exceeds_limit',
    });
    await expectLater(
      () => book(repo),
      throwsA(
        isA<RideBookingException>().having(
          (e) => e.reason,
          'reason',
          'reward_redemption_exceeds_limit',
        ),
      ),
    );
  });

  test('a network/RPC-level exception is wrapped, never left raw', () async {
    final repo = RideBookingRepository(
      _dummyClient(),
      rpcCaller: (fn, {params}) => throw Exception('connection reset'),
    );
    await expectLater(
      () => book(repo),
      throwsA(isA<RideBookingException>()),
    );
  });
}
