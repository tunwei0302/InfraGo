import 'package:supabase_flutter/supabase_flutter.dart';

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
}
