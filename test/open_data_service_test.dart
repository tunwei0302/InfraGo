import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/tey/analytics_screen.dart';
import 'package:infra_go/tey/sdg_analytics_repository.dart';

http.Response _jsonResponse(Object body, {int statusCode = 200}) =>
    http.Response(jsonEncode(body), statusCode);

Map<String, dynamic> _emptySdgResult() => {
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
    };

SdgAnalyticsRepository _fakeSdgRepo() => SdgAnalyticsRepository(
      SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      ),
      rpcCaller: (fn, {params}) async => _emptySdgResult(),
    );

void main() {
  testWidgets(
    'renders live fuel price, vehicle registration and ridership data '
    'from the real data.gov.my response shape',
    (tester) async {
      final service = OpenDataService(
        httpGet: (url) async {
          if (url.toString().contains('id=fuelprice')) {
            return _jsonResponse([
              {
                'date': '2026-08-27',
                'ron95': 3.82,
                'ron97': 4.30,
                'diesel': 4.72,
                'series_type': 'level',
              },
            ]);
          }
          if (url.toString().contains('id=registrations_type_fuel')) {
            return _jsonResponse([
              {
                'date': '2026-07-01',
                'fuel': 'petrol',
                'type': 'car',
                'registrations': 63977,
              },
            ]);
          }
          if (url.toString().contains('id=ridership_headline')) {
            return _jsonResponse([
              {'date': '2026-07-31', 'rail_lrt_kj': 302283},
            ]);
          }
          return _jsonResponse([]);
        },
      );

      await tester.pumpWidget(MaterialApp(
        home: AnalyticsScreen(service: service, sdgRepository: _fakeSdgRepo()),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('RM3.82'), findsOneWidget);
      expect(find.textContaining('RM4.30'), findsOneWidget);
      expect(find.textContaining('RM4.72'), findsOneWidget);
      expect(find.textContaining('63977 vehicles'), findsOneWidget);
      expect(find.textContaining('302283 riders/day'), findsOneWidget);
      expect(find.text('Official data LIVE'), findsOneWidget);
    },
  );

  testWidgets(
    'shows a source-specific error badge when a source 404s, without '
    'failing the whole dashboard',
    (tester) async {
      final service = OpenDataService(
        httpGet: (url) async {
          if (url.toString().contains('id=fuelprice')) {
            return _jsonResponse(
              {
                'status_code': 404,
                'details': ['not found'],
              },
              statusCode: 404,
            );
          }
          return _jsonResponse([
            {'date': '2026-07-31', 'rail_lrt_kj': 302283},
          ]);
        },
      );

      await tester.pumpWidget(MaterialApp(
        home: AnalyticsScreen(service: service, sdgRepository: _fakeSdgRepo()),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Data unavailable: HTTP 404'), findsOneWidget);
      expect(find.textContaining('302283 riders/day'), findsOneWidget);
    },
  );
}
