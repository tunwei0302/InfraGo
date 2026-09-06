import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/20260913000000_f_reward_transactions_type_check_fix.sql',
  ).readAsStringSync();

  test('re-widens reward_transactions_type_check to include earn', () {
    expect(
      sql,
      contains('DROP CONSTRAINT IF EXISTS reward_transactions_type_check'),
    );
    expect(
      sql,
      contains("CHECK (type IN ('demo_grant', 'earn', 'redeem', 'restore'))"),
    );
  });
}
