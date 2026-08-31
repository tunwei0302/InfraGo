import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/20260829000000_f_payments_wallet.sql',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  test('rides gains the cancellation and landmark fields Foo owns', () {
    expect(sql, contains('ADD COLUMN IF NOT EXISTS pickup_landmark_path'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS accepted_at'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS free_cancel_until'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS cancelled_by'));
    expect(
      sql,
      contains('ADD COLUMN IF NOT EXISTS cancellation_policy_version'),
    );
    expect(sql, contains('ADD COLUMN IF NOT EXISTS cancellation_fee'));
    expect(
      sql,
      contains(
        "cancelled_by IS NULL OR cancelled_by IN ('rider', 'driver', 'system')",
      ),
    );
  });

  test(
    'fare_quotes is append-only: insert/select policies but no update or delete',
    () {
      expect(sql, contains('fare_quotes_rider_read'));
      expect(sql, contains('fare_quotes_rider_insert'));
      expect(sql, isNot(contains('fare_quotes FOR UPDATE')));
      expect(sql, isNot(contains('fare_quotes FOR DELETE')));
      expect(
        sql,
        contains(
          "CHECK (service_type IN ('economy_4', 'six_seater', 'shared_economy'))",
        ),
      );
    },
  );

  test(
    'payments enforce one current payment per ride and idempotent retries',
    () {
      expect(
        sql,
        contains(
          "CREATE UNIQUE INDEX IF NOT EXISTS uq_payments_current_per_ride\n"
          "  ON payments(ride_id) WHERE status IN ('pending', 'authorised', 'paid');",
        ),
      );
      expect(sql, contains('idempotency_key TEXT NOT NULL UNIQUE'));
      expect(sql, contains('payment_already_exists'));
    },
  );

  test(
    'payments and wallet tables have no client write policy: RPCs own every mutation',
    () {
      for (final table in [
        'payments',
        'wallet_accounts',
        'wallet_transactions',
      ]) {
        expect(sql, isNot(contains('$table FOR INSERT')));
        expect(sql, isNot(contains('$table FOR UPDATE')));
        expect(sql, isNot(contains('$table FOR DELETE')));
      }
    },
  );

  test(
    'resolve_current_fare_amount is internal-only: never trusts a client-supplied amount',
    () {
      expect(sql, contains('RAISE EXCEPTION \'fare_quote_not_found\''));
      expect(
        sql,
        isNot(
          contains('GRANT EXECUTE ON FUNCTION resolve_current_fare_amount'),
        ),
      );
    },
  );

  test(
    'resolve_current_fare_amount applies the vehicle multiplier for economy_4/six_seater',
    () {
      final fnStart = sql.indexOf(
        'CREATE OR REPLACE FUNCTION resolve_current_fare_amount',
      );
      final fnEnd = sql.indexOf(
        'CREATE OR REPLACE FUNCTION ensure_wallet_account',
        fnStart,
      );
      final fnSql = sql.substring(fnStart, fnEnd);
      expect(
        fnSql,
        contains("IF v_quote.service_type = 'shared_economy' THEN"),
      );
      expect(fnSql, contains('v_ride.group_id IS NOT NULL'));
      expect(fnSql, contains('RETURN v_quote.solo_amount;'));
      expect(
        fnSql,
        contains(
          'RETURN ROUND((v_quote.base_amount * v_quote.vehicle_multiplier)::numeric, 2);',
        ),
      );
    },
  );

  test('authorise_wallet_payment checks balance before ever deducting it', () {
    final fnStart = sql.indexOf(
      'CREATE OR REPLACE FUNCTION authorise_wallet_payment',
    );
    final fnEnd = sql.indexOf(
      'CREATE OR REPLACE FUNCTION capture_wallet_payment',
      fnStart,
    );
    final fnSql = sql.substring(fnStart, fnEnd);
    final checkIndex = fnSql.indexOf('insufficient_balance');
    final deductIndex = fnSql.indexOf('balance = balance - v_charge');
    expect(checkIndex, greaterThan(-1));
    expect(deductIndex, greaterThan(checkIndex));
    expect(fnSql, contains('FOR UPDATE'));
  });

  test(
    'create_ride_with_quote_and_payment folds ride, quote and payment into one transaction',
    () {
      final fnStart = sql.indexOf(
        'CREATE OR REPLACE FUNCTION create_ride_with_quote_and_payment',
      );
      final fnEnd = sql.indexOf(
        'CREATE OR REPLACE FUNCTION cancel_ride_and_settle_payment',
        fnStart,
      );
      final fnSql = sql.substring(fnStart, fnEnd);
      expect(fnSql, contains('INSERT INTO rides'));
      expect(fnSql, contains('INSERT INTO fare_quotes'));
      expect(
        fnSql,
        contains(
          'v_ride_id, p_client_request_id, v_redemption_amount, p_reward_points_to_redeem',
        ),
      );
      expect(fnSql, contains("idempotent_replay"));
      final idempotencyCheckIndex = fnSql.indexOf(
        'SELECT * INTO v_existing_payment FROM payments WHERE idempotency_key',
      );
      final rideInsertIndex = fnSql.indexOf('INSERT INTO rides');
      expect(idempotencyCheckIndex, greaterThan(-1));
      expect(rideInsertIndex, greaterThan(idempotencyCheckIndex));
    },
  );

  test(
    'create_ride_with_quote_and_payment recomputes mvp_v1 fare itself, not from client input',
    () {
      final fnStart = sql.indexOf(
        'CREATE OR REPLACE FUNCTION create_ride_with_quote_and_payment',
      );
      final fnEnd = sql.indexOf(
        'CREATE OR REPLACE FUNCTION cancel_ride_and_settle_payment',
        fnStart,
      );
      final fnSql = sql.substring(fnStart, fnEnd);
      expect(fnSql, contains('3.0 + 1.10 * v_km + 0.20 * v_minutes'));
      expect(fnSql, contains('GREATEST(5.0, v_raw)'));
      expect(fnSql, contains("WHEN 'six_seater' THEN 1.35"));
      expect(fnSql, contains("WHEN 'shared_economy' THEN 0.75"));
    },
  );

  test(
    'cancel_ride_and_settle_payment writes cancellation fields exactly once',
    () {
      final fnStart = sql.indexOf(
        'CREATE OR REPLACE FUNCTION cancel_ride_and_settle_payment',
      );
      final fnEnd = sql.indexOf('REVOKE ALL ON FUNCTION', fnStart);
      final fnSql = sql.substring(fnStart, fnEnd);
      expect(fnSql, contains("status = 'cancelled'"));
      expect(fnSql, contains('cancelled_by = p_cancelled_by'));
      expect(fnSql, contains('cancellation_policy_version = p_policy_version'));
      expect(fnSql, contains("ride_not_cancellable"));
      expect(fnSql, contains("v_payment.method = 'cash'"));
      expect(fnSql, contains('GREATEST(v_held - p_fee, 0)'));
      expect(fnSql, contains('IF v_ride.group_id IS NOT NULL THEN'));
      expect(
        fnSql,
        contains("status = CASE WHEN status = 'matched' THEN 'waiting_match'"),
      );
      expect(fnSql, contains('DELETE FROM ride_group_members'));
      expect(fnSql, contains("UPDATE ride_groups SET status = 'cancelled'"));
    },
  );

  test('shared-to-solo conversion reprices ride and payment atomically', () {
    final fnStart = sql.indexOf(
      'CREATE OR REPLACE FUNCTION continue_shared_ride_solo',
    );
    final fnEnd = sql.indexOf(
      'CREATE OR REPLACE FUNCTION cancel_ride_and_settle_payment',
      fnStart,
    );
    final fnSql = sql.substring(fnStart, fnEnd);
    expect(fnSql, contains("service_type = 'economy_4'"));
    expect(fnSql, contains("status = 'requested'"));
    expect(fnSql, contains('INSERT INTO fare_quotes'));
    expect(fnSql, isNot(contains('UPDATE fare_quotes')));
    expect(fnSql, contains('quoted_amount = v_quote.solo_amount'));
    expect(fnSql, contains("AND status = 'pending' FOR UPDATE"));
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION continue_shared_ride_solo(UUID) TO authenticated',
      ),
    );
  });

  test(
    'reward redemption is validated and capped at 20% of fare before anything is created',
    () {
      final fnStart = sql.indexOf(
        'CREATE OR REPLACE FUNCTION create_ride_with_quote_and_payment',
      );
      final fnEnd = sql.indexOf(
        'CREATE OR REPLACE FUNCTION cancel_ride_and_settle_payment',
        fnStart,
      );
      final fnSql = sql.substring(fnStart, fnEnd);
      expect(fnSql, contains('p_reward_points_to_redeem INTEGER DEFAULT 0'));
      expect(fnSql, contains('reward_redemption_exceeds_limit'));
      expect(
        fnSql,
        contains('v_redemption_amount > ROUND(v_charge_amount * 0.20, 2)'),
      );
      expect(fnSql, contains('insufficient_reward_points'));
      final capCheckIndex = fnSql.indexOf('reward_redemption_exceeds_limit');
      final rideInsertIndex = fnSql.indexOf('INSERT INTO rides');
      expect(capCheckIndex, greaterThan(-1));
      expect(rideInsertIndex, greaterThan(capCheckIndex));
    },
  );

  test(
    'redeemed points are only debited after payment setup succeeds, in the same transaction',
    () {
      final fnStart = sql.indexOf(
        'CREATE OR REPLACE FUNCTION create_ride_with_quote_and_payment',
      );
      final fnEnd = sql.indexOf(
        'CREATE OR REPLACE FUNCTION cancel_ride_and_settle_payment',
        fnStart,
      );
      final fnSql = sql.substring(fnStart, fnEnd);
      final paymentFailIndex = fnSql.indexOf('payment_setup_failed');
      final redeemCallIndex = fnSql.indexOf('PERFORM redeem_reward_points');
      expect(paymentFailIndex, greaterThan(-1));
      expect(redeemCallIndex, greaterThan(paymentFailIndex));
    },
  );

  test(
    'cancellation restores redeemed reward points before settling the payment',
    () {
      final fnStart = sql.indexOf(
        'CREATE OR REPLACE FUNCTION cancel_ride_and_settle_payment',
      );
      final fnEnd = sql.indexOf('REVOKE ALL ON FUNCTION', fnStart);
      final fnSql = sql.substring(fnStart, fnEnd);
      final restoreIndex = fnSql.indexOf('PERFORM restore_reward_points');
      final cashBranchIndex = fnSql.indexOf("v_payment.method = 'cash'");
      expect(fnSql, contains('v_payment.reward_points_redeemed > 0'));
      expect(restoreIndex, greaterThan(-1));
      expect(restoreIndex, lessThan(cashBranchIndex));
    },
  );
}
