import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/tey/sdg_analytics_repository.dart';

SupabaseClient _dummyClient() =>
    SupabaseClient('https://example.supabase.co', 'test-anon-key');

Map<String, dynamic> _fullRpcResult() => {
      'success': true,
      'range': {'start': null, 'end': null},
      'sdg': {
        'completed_rides': 12,
        'transit_linked_rides': 3,
        'shared_groups_completed': 4,
        'avg_passengers_per_vehicle': 2.5,
        'avg_rider_detour_ratio': 0.12,
        'estimated_savings_myr': 18.4,
        'vehicle_km_avoided': 22.7,
      },
      'vehicle_capacity_distribution': [
        {'capacity': 4, 'count': 5},
        {'capacity': 6, 'count': 1},
      ],
      'service_category_distribution': [
        {'service_type': 'economy_4', 'count': 8},
        {'service_type': 'shared_economy', 'count': 4},
      ],
      'cancellations': {
        'cancelled_count': 2,
        'completed_count': 12,
        'free_cancellation_count': 1,
        'fee_cancellation_count': 1,
        'top_reasons': [
          {'reason': 'driver_no_show', 'count': 1},
        ],
        'prototype_driver_compensation_myr': 3.5,
      },
      'payments': [
        {'method': 'cash', 'status': 'paid', 'count': 8, 'total_myr': 96.0},
        {
          'method': 'demo_wallet',
          'status': 'paid',
          'count': 4,
          'total_myr': 41.0,
        },
      ],
    };

void main() {
  group('fetchSnapshot', () {
    test('parses a full RPC result into a snapshot', () async {
      Map<String, dynamic>? calledParams;
      final repo = SdgAnalyticsRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async {
          expect(fn, 'sdg_operational_analytics');
          calledParams = params;
          return _fullRpcResult();
        },
      );

      final snapshot = await repo.fetchSnapshot();

      expect(calledParams, isEmpty);
      expect(snapshot.completedRides, 12);
      expect(snapshot.transitLinkedRides, 3);
      expect(snapshot.sharedGroupsCompleted, 4);
      expect(snapshot.avgPassengersPerVehicle, 2.5);
      expect(snapshot.avgRiderDetourRatio, 0.12);
      expect(snapshot.estimatedSavingsMYR, 18.4);
      expect(snapshot.vehicleKmAvoided, 22.7);
      expect(snapshot.vehicleCapacityDistribution, hasLength(2));
      expect(snapshot.vehicleCapacityDistribution.first.capacity, 4);
      expect(snapshot.serviceCategoryDistribution.first.serviceType,
          'economy_4');
      expect(snapshot.cancelledCount, 2);
      expect(snapshot.completedCountForCancellation, 12);
      expect(snapshot.cancellationRate, closeTo(2 / 14, 1e-9));
      expect(snapshot.topCancellationReasons.single.reason, 'driver_no_show');
      expect(snapshot.prototypeDriverCompensationMYR, 3.5);
      expect(snapshot.paymentAggregates, hasLength(2));
      expect(snapshot.paymentAggregates.first.totalMYR, 96.0);
    });

    test('passes start/end as UTC ISO8601 params', () async {
      Map<String, dynamic>? calledParams;
      final repo = SdgAnalyticsRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async {
          calledParams = params;
          return _fullRpcResult();
        },
      );

      final start = DateTime.utc(2026, 1, 1);
      await repo.fetchSnapshot(start: start);

      expect(calledParams, isNotNull);
      expect(calledParams!['p_start'], start.toIso8601String());
      expect(calledParams!.containsKey('p_end'), isFalse);
    });

    test('cancellationRate is null when there is no data yet', () async {
      final repo = SdgAnalyticsRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async => {
          'success': true,
          'sdg': {
            'completed_rides': 0,
            'transit_linked_rides': 0,
            'shared_groups_completed': 0,
            'avg_passengers_per_vehicle': null,
            'avg_rider_detour_ratio': null,
            'estimated_savings_myr': 0,
            'vehicle_km_avoided': 0,
          },
          'vehicle_capacity_distribution': [],
          'service_category_distribution': [],
          'cancellations': {
            'cancelled_count': 0,
            'completed_count': 0,
            'free_cancellation_count': 0,
            'fee_cancellation_count': 0,
            'top_reasons': [],
            'prototype_driver_compensation_myr': 0,
          },
          'payments': [],
        },
      );

      final snapshot = await repo.fetchSnapshot();
      expect(snapshot.cancellationRate, isNull);
      expect(snapshot.avgPassengersPerVehicle, isNull);
      expect(snapshot.avgRiderDetourRatio, isNull);
      expect(snapshot.completedRides, 0);
    });

    test('throws SdgAnalyticsException when the RPC reports failure',
        () async {
      final repo = SdgAnalyticsRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async =>
            {'success': false, 'reason': 'authentication_required'},
      );

      await expectLater(
        () => repo.fetchSnapshot(),
        throwsA(isA<SdgAnalyticsException>()),
      );
    });

    test('rejects a start date after the end date without calling the RPC',
        () async {
      var called = false;
      final repo = SdgAnalyticsRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async {
          called = true;
          return _fullRpcResult();
        },
      );

      await expectLater(
        () => repo.fetchSnapshot(
          start: DateTime.utc(2026, 2, 1),
          end: DateTime.utc(2026, 1, 1),
        ),
        throwsA(isA<SdgAnalyticsException>()),
      );
      expect(called, isFalse);
    });
  });
}
