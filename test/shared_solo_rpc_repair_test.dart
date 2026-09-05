import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/20260906000000_f_restore_shared_solo_rpc.sql',
  ).readAsStringSync();

  test('repair migration installs the missing atomic solo conversion RPC', () {
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION continue_shared_ride_solo(p_ride_id UUID)',
      ),
    );
    expect(sql, contains("v_ride.service_type != 'shared_economy'"));
    expect(sql, contains('v_ride.group_id IS NOT NULL'));
    expect(
      sql,
      contains("v_ride.status NOT IN ('requested', 'waiting_match')"),
    );
    expect(sql, contains("service_type = 'economy_4'"));
    expect(sql, contains('quoted_amount = v_quote.solo_amount'));
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION continue_shared_ride_solo(UUID) TO authenticated',
      ),
    );
  });
}
