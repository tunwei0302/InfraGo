import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/20260829000000_f_payments_wallet.sql',
  ).readAsStringSync();

  test('rides gains the cancellation and landmark fields Foo owns', () {
    expect(sql, contains('ADD COLUMN IF NOT EXISTS pickup_landmark_path'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS accepted_at'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS free_cancel_until'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS cancelled_by'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS cancellation_policy_version'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS cancellation_fee'));
    expect(
      sql,
      contains("cancelled_by IS NULL OR cancelled_by IN ('rider', 'driver', 'system')"),
    );
  });

  test('fare_quotes is append-only: insert/select policies but no update or delete', () {
    expect(sql, contains('fare_quotes_rider_read'));
    expect(sql, contains('fare_quotes_rider_insert'));
    expect(sql, isNot(contains('fare_quotes FOR UPDATE')));
    expect(sql, isNot(contains('fare_quotes FOR DELETE')));
    expect(
      sql,
      contains("CHECK (service_type IN ('economy_4', 'six_seater', 'shared_economy'))"),
    );
  });

  test('payments enforce one current payment per ride and idempotent retries', () {
    expect(
      sql,
      contains(
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_payments_current_per_ride\n"
        "  ON payments(ride_id) WHERE status IN ('pending', 'authorised', 'paid');",
      ),
    );
    expect(sql, contains('idempotency_key TEXT NOT NULL UNIQUE'));
    expect(sql, contains('payment_already_exists'));
  });

  test('payments and wallet tables have no client write policy: RPCs own every mutation', () {
    for (final table in ['payments', 'wallet_accounts', 'wallet_transactions']) {
      expect(sql, isNot(contains('$table FOR INSERT')));
      expect(sql, isNot(contains('$table FOR UPDATE')));
      expect(sql, isNot(contains('$table FOR DELETE')));
    }
  });

  test('resolve_current_fare_amount is internal-only: never trusts a client-supplied amount', () {
    expect(sql, contains('RAISE EXCEPTION \'fare_quote_not_found\''));
    expect(
      sql,
      isNot(contains('GRANT EXECUTE ON FUNCTION resolve_current_fare_amount')),
    );
    expect(
      sql,
      contains("v_quote.service_type = 'shared_economy' AND v_ride.group_id IS NOT NULL"),
    );
  });

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

  test('cancel_ride_and_settle_payment writes cancellation fields exactly once', () {
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
  });
}
