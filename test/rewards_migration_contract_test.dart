import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/20260831000000_t_rewards.sql',
  ).readAsStringSync();

  test('reward ledger is immutable: no client insert/update/delete policy', () {
    for (final table in ['reward_accounts', 'reward_transactions']) {
      expect(sql, isNot(contains('$table FOR INSERT')));
      expect(sql, isNot(contains('$table FOR UPDATE')));
      expect(sql, isNot(contains('$table FOR DELETE')));
    }
    expect(sql, contains('reward_accounts_owner_read'));
    expect(sql, contains('reward_transactions_owner_read'));
  });

  test('demo_reward_grant is capped and coursework-only', () {
    final fnStart = sql.indexOf('CREATE OR REPLACE FUNCTION demo_reward_grant');
    final fnEnd = sql.indexOf(
      'CREATE OR REPLACE FUNCTION redeem_reward_points',
      fnStart,
    );
    final fnSql = sql.substring(fnStart, fnEnd);
    expect(fnSql, contains('p_points > 1000'));
    expect(fnSql, contains('demo_balance_cap_exceeded'));
    expect(fnSql, contains('FOR UPDATE'));
  });

  test(
    'redeem_reward_points checks balance before debiting and writes a ledger entry',
    () {
      final fnStart = sql.indexOf(
        'CREATE OR REPLACE FUNCTION redeem_reward_points',
      );
      final fnEnd = sql.indexOf(
        'CREATE OR REPLACE FUNCTION restore_reward_points',
        fnStart,
      );
      final fnSql = sql.substring(fnStart, fnEnd);
      final checkIndex = fnSql.indexOf('insufficient_reward_points');
      final debitIndex = fnSql.indexOf(
        'points_balance = points_balance - p_points',
      );
      final ledgerIndex = fnSql.indexOf("'redeem'");
      expect(checkIndex, greaterThan(-1));
      expect(debitIndex, greaterThan(checkIndex));
      expect(ledgerIndex, greaterThan(debitIndex));
    },
  );

  test(
    'restore_reward_points credits points back and writes a ledger entry',
    () {
      final fnStart = sql.indexOf(
        'CREATE OR REPLACE FUNCTION restore_reward_points',
      );
      final fnEnd = sql.indexOf('REVOKE ALL ON FUNCTION', fnStart);
      final fnSql = sql.substring(fnStart, fnEnd);
      expect(fnSql, contains('points_balance = points_balance + p_points'));
      expect(fnSql, contains("'restore'"));
    },
  );

  test(
    'the internal redeem/restore helpers are never granted to authenticated clients',
    () {
      expect(
        sql,
        isNot(contains('GRANT EXECUTE ON FUNCTION redeem_reward_points')),
      );
      expect(
        sql,
        isNot(contains('GRANT EXECUTE ON FUNCTION restore_reward_points')),
      );
      expect(
        sql,
        contains(
          'GRANT EXECUTE ON FUNCTION ensure_reward_account() TO authenticated',
        ),
      );
      expect(
        sql,
        contains(
          'GRANT EXECUTE ON FUNCTION demo_reward_grant(INTEGER) TO authenticated',
        ),
      );
    },
  );
}
