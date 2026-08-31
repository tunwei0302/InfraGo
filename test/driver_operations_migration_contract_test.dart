import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/20260902000000_h_driver_operations.sql',
  ).readAsStringSync();

  test('driver identity, one vehicle and private documents are defined', () {
    expect(sql, contains('CREATE TABLE IF NOT EXISTS driver_verifications'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS driver_vehicles'));
    expect(sql, contains('driver_id UUID PRIMARY KEY'));
    expect(sql, contains("'driver-documents', 'driver-documents', FALSE"));
    expect(sql, contains("(storage.foldername(name))[1] = auth.uid()::TEXT"));
    expect(sql, contains("plate_number ~ '^[A-Z0-9]{3,12}\$'"));
    expect(sql, contains('passenger_capacity BETWEEN 1 AND 6'));
  });

  test('online presence is approval-gated and coarse', () {
    final start = sql.indexOf(
      'CREATE OR REPLACE FUNCTION upsert_my_driver_presence',
    );
    final end = sql.indexOf(
      'CREATE OR REPLACE FUNCTION accept_available_ride',
      start,
    );
    final function = sql.substring(start, end);
    expect(function, contains('driver_verification_not_approved'));
    expect(function, contains('vehicle_not_approved'));
    expect(function, contains("round(p_coarse_lat::numeric, 3)"));
    expect(function, contains("array_append(v_categories, 'six_seater')"));
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION publish_assigned_driver_location'),
    );
    expect(sql, contains("status IN ('driver_assigned', 'en_route')"));
    expect(sql, contains('vehicle_plate = EXCLUDED.vehicle_plate'));
  });

  test('acceptance locks, checks capacity and has exactly one winner', () {
    final start = sql.indexOf(
      'CREATE OR REPLACE FUNCTION accept_available_ride',
    );
    final end = sql.indexOf(
      'CREATE OR REPLACE FUNCTION accept_carpool_group',
      start,
    );
    final function = sql.substring(start, end);
    expect(function, contains('FOR UPDATE'));
    expect(function, contains("v_ride.status != 'requested'"));
    expect(
      function,
      contains('v_vehicle.passenger_capacity < v_ride.passenger_count'),
    );
    expect(function, contains("status = 'driver_assigned'"));
  });

  test(
    'lifecycle rejects invalid changes and requires cancellation reason',
    () {
      expect(sql, contains("'invalid_transition'"));
      expect(sql, contains("'cancellation_reason_required'"));
      expect(sql, contains("p_next_status IN ('completed', 'cancelled')"));
      expect(sql, contains('DELETE FROM assigned_driver_location'));
    },
  );
}
