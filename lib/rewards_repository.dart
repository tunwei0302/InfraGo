import 'package:supabase_flutter/supabase_flutter.dart';

class RewardsException implements Exception {
  const RewardsException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

class RewardsRepository {
  const RewardsRepository(this.client);

  final SupabaseClient client;

  Future<int> ensureRewardAccount() async {
    final result = await client.rpc('ensure_reward_account');
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw RewardsException(
        map['reason']?.toString() ?? 'reward_account_unavailable',
      );
    }
    return (map['points_balance'] as num).toInt();
  }

  Future<int> demoGrant(int points) async {
    final result = await client.rpc(
      'demo_reward_grant',
      params: {'p_points': points},
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw RewardsException(map['reason']?.toString() ?? 'grant_failed');
    }
    return (map['points_balance'] as num).toInt();
  }
}
