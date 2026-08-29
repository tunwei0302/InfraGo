import 'package:supabase_flutter/supabase_flutter.dart';

import 'payment_method.dart';

class PaymentException implements Exception {
  const PaymentException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

class PaymentRepository {
  const PaymentRepository(this.client);

  final SupabaseClient client;

  Future<Map<String, dynamic>> ensureWalletAccount() async {
    final result = await client.rpc('ensure_wallet_account');
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> topUpDemoWallet(double amount) async {
    final result = await client.rpc(
      'demo_wallet_top_up',
      params: {'p_amount': amount},
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw PaymentException(map['reason']?.toString() ?? 'top_up_failed');
    }
    return map;
  }

  Future<Map<String, dynamic>> createPayment({
    required String rideId,
    required PaymentMethod method,
  }) async {
    final function = method == PaymentMethod.cash
        ? 'create_cash_payment'
        : 'create_wallet_payment';
    final result = await client.rpc(
      function,
      params: {'p_ride_id': rideId, 'p_idempotency_key': rideId},
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw PaymentException(map['reason']?.toString() ?? 'payment_failed');
    }
    return map;
  }
}
