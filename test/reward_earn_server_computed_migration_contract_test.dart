import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/20260912000000_f_reward_earn_server_computed.sql',
  ).readAsStringSync();

  test('the insecure 4-arg version (client-supplied user/points) is dropped', () {
    expect(
      sql,
      contains(
        'DROP FUNCTION IF EXISTS earn_completion_reward(UUID, UUID, UUID, INTEGER)',
      ),
    );
  });

  test(
    'the replacement only accepts ride_id and payment_id — never a user or points',
    () {
      final start = sql.indexOf(
        'CREATE OR REPLACE FUNCTION earn_completion_reward',
      );
      final end = sql.indexOf(')', start);
      final signature = sql.substring(start, end);
      expect(signature, contains('p_ride_id UUID'));
      expect(signature, contains('p_payment_id UUID'));
      expect(signature, isNot(contains('p_user_id')));
      expect(signature, isNot(contains('p_points')));
    },
  );

  test('only a participant of the ride (rider or driver) may trigger it', () {
    expect(
      sql,
      contains('auth.uid() NOT IN (v_ride.rider_id, v_ride.driver_id)'),
    );
    expect(sql, contains('not_a_ride_participant'));
  });

  test(
    'points are computed from the payment\'s own final_amount, not trusted from the caller',
    () {
      expect(
        sql,
        contains(
          'v_points := floor(COALESCE(v_payment.final_amount, 0) * 10)::INTEGER',
        ),
      );
    },
  );

  test('the payment must belong to this exact ride and already be paid', () {
    expect(sql, contains('v_payment.ride_id <> p_ride_id'));
    expect(sql, contains("v_payment.status <> 'paid'"));
  });

  test(
    'points are always credited to the ride\'s rider, never an arbitrary caller-supplied id',
    () {
      final insertIndex = sql.indexOf(
        "VALUES (\n    v_ride.rider_id, p_ride_id, p_payment_id, 'earn'",
      );
      expect(insertIndex, greaterThan(-1));
      expect(sql, contains('reward_accounts WHERE user_id = v_ride.rider_id'));
    },
  );

  test('at most one earn per ride is still enforced before crediting', () {
    expect(sql, contains("WHERE ride_id = p_ride_id AND type = 'earn'"));
    expect(sql, contains('already_awarded'));
  });

  test('function stays restricted to authenticated callers only', () {
    expect(
      sql,
      contains(
        'REVOKE ALL ON FUNCTION earn_completion_reward(UUID, UUID) FROM PUBLIC',
      ),
    );
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION earn_completion_reward(UUID, UUID) TO authenticated',
      ),
    );
  });
}
