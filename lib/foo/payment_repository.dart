import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/shared/rpc_caller.dart';

class PaymentException implements Exception {
  const PaymentException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

class PaymentRepository {
  PaymentRepository(SupabaseClient client, {RpcCaller? rpcCaller})
    : _rpc = rpcCaller ?? client.rpc;

  final RpcCaller _rpc;

  Future<Map<String, dynamic>> ensureWalletAccount() async {
    final result = await _rpc('ensure_wallet_account');
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> topUpDemoWallet(double amount) async {
    final result = await _rpc(
      'demo_wallet_top_up',
      params: {'p_amount': amount},
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw PaymentException(map['reason']?.toString() ?? 'top_up_failed');
    }
    return map;
  }

  Future<Map<String, dynamic>> authoriseWalletPayment(String rideId) async {
    final result = await _rpc(
      'authorise_wallet_payment',
      params: {'p_ride_id': rideId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> completeCashPayment(String rideId) async {
    final result = await _rpc(
      'complete_cash_payment',
      params: {'p_ride_id': rideId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> captureWalletPayment(String rideId) async {
    final result = await _rpc(
      'capture_wallet_payment',
      params: {'p_ride_id': rideId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> cancelRideAndSettlePayment({
    required String rideId,
    required String cancelledBy,
    required String reason,
    required String policyVersion,
    required double fee,
    double driverCompensation = 0,
  }) async {
    final result = await _rpc(
      'cancel_ride_and_settle_payment',
      params: {
        'p_ride_id': rideId,
        'p_cancelled_by': cancelledBy,
        'p_reason': reason,
        'p_policy_version': policyVersion,
        'p_fee': fee,
        'p_driver_compensation': driverCompensation,
      },
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw PaymentException(
        map['reason']?.toString() ?? 'cancellation_failed',
      );
    }
    return map;
  }
}
