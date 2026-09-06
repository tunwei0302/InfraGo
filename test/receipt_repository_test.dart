import 'package:flutter_test/flutter_test.dart';

import 'package:infra_go/foo/receipt_repository.dart';

Map<String, dynamic> _bookedRideJson() => {
  'id': 'ride-1',
  'driver_id': 'driver-1',
  'pickup': 'Home, Jalan Ampang',
  'destination': 'Office, KLCC',
  'pickup_latitude': 3.1390,
  'pickup_longitude': 101.6869,
  'destination_latitude': 3.1580,
  'destination_longitude': 101.7113,
  'service_type': 'six_seater',
  'status': 'requested',
  'departure_time': '2026-08-29T12:00:00Z',
  'route_distance_meters': 10000.0,
  'route_duration_seconds': 1200.0,
  'cancelled_at': null,
  'cancellation_reason': null,
  'fare_quotes': [
    {
      'pricing_version': 'mvp_v1',
      'service_type': 'six_seater',
      'base_amount': 18.0,
      'vehicle_multiplier': 1.35,
      'solo_amount': 18.0,
      'shared_amount': null,
      'currency': 'MYR',
      'quoted_at': '2026-08-29T11:55:00Z',
    },
  ],
  'payments': [
    {
      'method': 'cash',
      'status': 'pending',
      'quoted_amount': 24.30,
      'discount_amount': 0.0,
      'reward_points_redeemed': 0,
      'cancellation_fee': 0.0,
      'refunded_amount': 0.0,
      'final_amount': null,
      'currency': 'MYR',
      'created_at': '2026-08-29T11:55:00Z',
      'updated_at': '2026-08-29T11:55:00Z',
    },
  ],
};

Map<String, dynamic> _refundedRideJson() {
  final json = Map<String, dynamic>.from(_bookedRideJson());
  json['status'] = 'cancelled';
  json['cancelled_at'] = '2026-08-29T12:02:00Z';
  json['cancellation_reason'] = 'Rider cancelled';
  json['payments'] = [
    {
      'method': 'demo_wallet',
      'status': 'refunded',
      'quoted_amount': 24.30,
      'discount_amount': 0.0,
      'reward_points_redeemed': 0,
      'cancellation_fee': 3.0,
      'refunded_amount': 21.30,
      'final_amount': 3.0,
      'currency': 'MYR',
      'created_at': '2026-08-29T11:55:00Z',
      'updated_at': '2026-08-29T12:02:00Z',
    },
  ];
  return json;
}

void main() {
  test(
    'booking-to-receipt: a freshly booked ride parses route, category and fare breakdown',
    () {
      final receipt = ReceiptData.fromJson(_bookedRideJson());

      expect(receipt.pickupLabel, 'Home, Jalan Ampang');
      expect(receipt.destinationLabel, 'Office, KLCC');
      expect(receipt.driverId, 'driver-1');
      expect(receipt.serviceType, 'six_seater');
      expect(receipt.status, 'requested');

      final quote = receipt.fareQuote;
      expect(quote, isNotNull);
      expect(quote!.baseAmount, 18.0);
      expect(quote.vehicleMultiplier, 1.35);
      expect(quote.sharedAmount, isNull);

      final payment = receipt.payment;
      expect(payment, isNotNull);
      expect(payment!.method, 'cash');
      expect(payment.status, 'pending');
      expect(payment.quotedAmount, 24.30);
      expect(payment.finalAmount, isNull);
    },
  );

  test(
    'booking-to-refund: a cancelled+refunded ride parses fee, refund and final amount',
    () {
      final receipt = ReceiptData.fromJson(_refundedRideJson());

      expect(receipt.status, 'cancelled');
      expect(receipt.cancelledAt, DateTime.parse('2026-08-29T12:02:00Z'));
      expect(receipt.cancellationReason, 'Rider cancelled');

      final payment = receipt.payment!;
      expect(payment.status, 'refunded');
      expect(payment.method, 'demo_wallet');
      expect(payment.cancellationFee, 3.0);
      expect(payment.refundedAmount, 21.30);
      expect(payment.finalAmount, 3.0);

      expect(
        payment.refundedAmount + payment.cancellationFee,
        payment.quotedAmount,
      );
    },
  );

  test('a ride still waiting for a driver has no driver id yet', () {
    final json = Map<String, dynamic>.from(_bookedRideJson());
    json['driver_id'] = null;

    final receipt = ReceiptData.fromJson(json);
    expect(receipt.driverId, isNull);
  });

  test(
    'a ride with no fare_quotes/payments yet does not crash the receipt',
    () {
      final json = Map<String, dynamic>.from(_bookedRideJson());
      json['fare_quotes'] = <Map<String, dynamic>>[];
      json['payments'] = <Map<String, dynamic>>[];

      final receipt = ReceiptData.fromJson(json);
      expect(receipt.fareQuote, isNull);
      expect(receipt.payment, isNull);
    },
  );

  test('a matched shared ride reports both the solo and shared amounts', () {
    final json = Map<String, dynamic>.from(_bookedRideJson());
    json['service_type'] = 'shared_economy';
    json['fare_quotes'] = [
      {
        'pricing_version': 'mvp_v1',
        'service_type': 'shared_economy',
        'base_amount': 18.0,
        'vehicle_multiplier': 0.75,
        'solo_amount': 18.0,
        'shared_amount': 13.5,
        'currency': 'MYR',
        'quoted_at': '2026-08-29T11:55:00Z',
      },
    ];

    final quote = ReceiptData.fromJson(json).fareQuote!;
    expect(quote.soloAmount, 18.0);
    expect(quote.sharedAmount, 13.5);
  });
}
