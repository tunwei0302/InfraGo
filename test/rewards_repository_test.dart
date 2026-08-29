import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/rewards_repository.dart';

SupabaseClient _dummyClient() =>
    SupabaseClient('https://example.supabase.co', 'test-anon-key');

void main() {
  group('ensureRewardAccount', () {
    test('returns the points balance on success', () async {
      final repo = RewardsRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async =>
            {'success': true, 'points_balance': 250},
      );
      expect(await repo.ensureRewardAccount(), 250);
    });

    test('throws RewardsException on failure', () async {
      final repo = RewardsRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async =>
            {'success': false, 'reason': 'authentication_required'},
      );
      await expectLater(
        () => repo.ensureRewardAccount(),
        throwsA(isA<RewardsException>()),
      );
    });
  });

  group('demoGrant', () {
    test('returns the new balance on success', () async {
      late Map<String, dynamic>? calledParams;
      final repo = RewardsRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async {
          calledParams = params;
          return {'success': true, 'points_balance': 100};
        },
      );
      final balance = await repo.demoGrant(100);
      expect(balance, 100);
      expect(calledParams!['p_points'], 100);
    });

    test('throws RewardsException when the demo cap is exceeded', () async {
      final repo = RewardsRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async =>
            {'success': false, 'reason': 'demo_balance_cap_exceeded'},
      );
      await expectLater(
        () => repo.demoGrant(999999),
        throwsA(
          isA<RewardsException>().having(
            (e) => e.reason,
            'reason',
            'demo_balance_cap_exceeded',
          ),
        ),
      );
    });
  });
}
