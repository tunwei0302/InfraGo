import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/20260828000000_k_trip_planner.sql',
  ).readAsStringSync();

  test('shared ride schema enforces service and passenger limits', () {
    expect(sql, contains("'economy_4', 'six_seater', 'shared_economy'"));
    expect(
      sql,
      contains("service_type != 'shared_economy' OR passenger_count <= 2"),
    );
    expect(sql, contains('total_passengers BETWEEN 2 AND 4'));
    expect(sql, contains('p_detour_a > 25'));
    expect(sql, contains('p_match_score < 60'));
  });

  test(
    'carpool RPC authenticates ownership and handles concurrent matches',
    () {
      expect(sql, contains('not_a_ride_owner'));
      expect(sql, contains('auth.uid() NOT IN'));
      expect(sql, contains('FOR UPDATE'));
      expect(sql, contains('concurrent_match_lost'));
    },
  );

  test('pre-assignment vehicle view never selects driver id', () {
    final viewStart = sql.indexOf(
      'CREATE OR REPLACE VIEW nearby_driver_presence',
    );
    final viewEnd = sql.indexOf('REVOKE ALL ON driver_presence', viewStart);
    final viewSql = sql.substring(viewStart, viewEnd);
    expect(viewSql, isNot(contains('driver_id')));
    expect(viewSql, contains("INTERVAL '60 seconds'"));
    expect(
      sql,
      contains('REVOKE ALL ON driver_presence FROM anon, authenticated'),
    );
    expect(sql, contains("'V-' || upper(substr(md5(auth.uid()::TEXT"));
  });

  test('chat RLS is ride-scoped and writable only during active ride', () {
    expect(sql, contains('r.id = messages.ride_id'));
    expect(sql, contains("r.status IN ('driver_assigned', 'en_route')"));
    expect(sql, contains('sender_id = auth.uid()'));
  });
}
