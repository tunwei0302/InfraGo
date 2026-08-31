import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('solo and shared acceptance use conditional database RPCs', () {
    final screen = File(
      'lib/heng/available_orders_screen.dart',
    ).readAsStringSync();
    final repository = File(
      'lib/heng/driver_repository.dart',
    ).readAsStringSync();
    expect(screen, contains('await _repository.acceptRide'));
    expect(screen, contains('await _repository.acceptGroup'));
    expect(screen, isNot(contains(".update({'driver_id'")));
    expect(repository, contains("'accept_available_ride'"));
    expect(repository, contains("'accept_carpool_group'"));
  });

  test('accepted ride opens the rider contact lifecycle', () {
    final sql = File(
      'supabase/migrations/20260902000000_h_driver_operations.sql',
    ).readAsStringSync();
    expect(sql, contains("status = 'driver_assigned'"));
    expect(sql, contains('accepted_at = now()'));
    expect(sql, contains("free_cancel_until = now() + INTERVAL '2 minutes'"));
  });
}
