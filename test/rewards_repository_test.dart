import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/tey/rewards_repository.dart';

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

  group('earnCompletionReward', () {
    test('sends only rideId/paymentId — never a client-supplied user or points', () async {
      late String calledFn;
      late Map<String, dynamic>? calledParams;
      final repo = RewardsRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async {
          calledFn = fn;
          calledParams = params;
          return {'success': true, 'points_balance': 150, 'points_awarded': 150};
        },
      );
      await repo.earnCompletionReward(rideId: 'ride-1', paymentId: 'payment-1');
      expect(calledFn, 'earn_completion_reward');
      expect(calledParams, {'p_ride_id': 'ride-1', 'p_payment_id': 'payment-1'});
      expect(calledParams!.containsKey('p_user_id'), isFalse);
      expect(calledParams!.containsKey('p_points'), isFalse);
    });

    test('refuses an empty rideId or paymentId without calling the RPC', () async {
      var called = false;
      final repo = RewardsRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async {
          called = true;
          return {'success': true};
        },
      );
      await expectLater(
        () => repo.earnCompletionReward(rideId: '', paymentId: 'payment-1'),
        throwsA(isA<RewardsException>()),
      );
      expect(called, isFalse);
    });

    test('throws RewardsException when the ride is not a completed+paid ride', () async {
      final repo = RewardsRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async =>
            {'success': false, 'reason': 'ride_not_completed'},
      );
      await expectLater(
        () => repo.earnCompletionReward(rideId: 'ride-1', paymentId: 'payment-1'),
        throwsA(
          isA<RewardsException>().having(
            (e) => e.reason,
            'reason',
            'ride_not_completed',
          ),
        ),
      );
    });
  });
}
