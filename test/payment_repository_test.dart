import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/foo/payment_repository.dart';

SupabaseClient _dummyClient() =>
    SupabaseClient('https://example.supabase.co', 'test-anon-key');

void main() {
  group('topUpDemoWallet', () {
    test('returns the new balance on success', () async {
      final repo = PaymentRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async =>
            {'success': true, 'balance': 50.0},
      );
      final result = await repo.topUpDemoWallet(50);
      expect(result['balance'], 50.0);
    });

    test('throws PaymentException with the server reason on failure', () async {
      final repo = PaymentRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async =>
            {'success': false, 'reason': 'demo_balance_cap_exceeded'},
      );
      await expectLater(
        () => repo.topUpDemoWallet(9999),
        throwsA(
          isA<PaymentException>().having(
            (e) => e.reason,
            'reason',
            'demo_balance_cap_exceeded',
          ),
        ),
      );
    });
  });

  group('authoriseWalletPayment', () {
    test('passes through insufficient_balance without throwing', () async {
      final repo = PaymentRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async => {
          'success': false,
          'reason': 'insufficient_balance',
          'balance': 2.0,
          'required': 10.0,
        },
      );
      final result = await repo.authoriseWalletPayment('ride-1');
      expect(result['reason'], 'insufficient_balance');
    });

    test('passes through payment_not_found for a cash ride without throwing', () async {
      final repo = PaymentRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async =>
            {'success': false, 'reason': 'payment_not_found'},
      );
      final result = await repo.authoriseWalletPayment('ride-1');
      expect(result['reason'], 'payment_not_found');
    });

    test('sends the ride id as p_ride_id', () async {
      late Map<String, dynamic>? calledParams;
      final repo = PaymentRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async {
          calledParams = params;
          return {'success': true, 'status': 'authorised'};
        },
      );
      await repo.authoriseWalletPayment('ride-42');
      expect(calledParams!['p_ride_id'], 'ride-42');
    });
  });

  group('completeCashPayment', () {
    test('passes through payment_not_found for a wallet ride without throwing', () async {
      final repo = PaymentRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async =>
            {'success': false, 'reason': 'payment_not_found'},
      );
      final result = await repo.completeCashPayment('ride-1');
      expect(result['reason'], 'payment_not_found');
    });

    test('returns paid status on success', () async {
      final repo = PaymentRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async =>
            {'success': true, 'payment_id': 'payment-1', 'status': 'paid'},
      );
      final result = await repo.completeCashPayment('ride-1');
      expect(result['status'], 'paid');
    });
  });

  group('captureWalletPayment', () {
    test('passes through payment_not_found for a cash ride without throwing', () async {
      final repo = PaymentRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async =>
            {'success': false, 'reason': 'payment_not_found'},
      );
      final result = await repo.captureWalletPayment('ride-1');
      expect(result['reason'], 'payment_not_found');
    });

    test('returns paid status on success', () async {
      late Map<String, dynamic>? calledParams;
      final repo = PaymentRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async {
          calledParams = params;
          return {'success': true, 'status': 'paid'};
        },
      );
      final result = await repo.captureWalletPayment('ride-7');
      expect(result['status'], 'paid');
      expect(calledParams!['p_ride_id'], 'ride-7');
    });
  });

  group('cancelRideAndSettlePayment', () {
    test('returns the settlement result on success', () async {
      final repo = PaymentRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async => {
          'success': true,
          'payment_id': 'payment-1',
          'method': 'demo_wallet',
          'refunded_amount': 8.0,
        },
      );
      final result = await repo.cancelRideAndSettlePayment(
        rideId: 'ride-1',
        cancelledBy: 'rider',
        reason: 'Rider cancelled',
        policyVersion: 'cancel_v1',
        fee: 2.0,
      );
      expect(result['refunded_amount'], 8.0);
    });

    test('throws PaymentException when the ride is no longer cancellable', () async {
      final repo = PaymentRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async =>
            {'success': false, 'reason': 'ride_not_cancellable'},
      );
      await expectLater(
        () => repo.cancelRideAndSettlePayment(
          rideId: 'ride-1',
          cancelledBy: 'rider',
          reason: 'Rider cancelled',
          policyVersion: 'cancel_v1',
          fee: 0,
        ),
        throwsA(
          isA<PaymentException>().having(
            (e) => e.reason,
            'reason',
            'ride_not_cancellable',
          ),
        ),
      );
    });

    test('sends the exact fee and policy version computed client-side', () async {
      late Map<String, dynamic>? calledParams;
      final repo = PaymentRepository(
        _dummyClient(),
        rpcCaller: (fn, {params}) async {
          calledParams = params;
          return {'success': true};
        },
      );
      await repo.cancelRideAndSettlePayment(
        rideId: 'ride-1',
        cancelledBy: 'rider',
        reason: 'Rider cancelled',
        policyVersion: 'cancel_v1',
        fee: 3.5,
      );
      expect(calledParams!['p_fee'], 3.5);
      expect(calledParams!['p_policy_version'], 'cancel_v1');
      expect(calledParams!['p_cancelled_by'], 'rider');
    });
  });
}
