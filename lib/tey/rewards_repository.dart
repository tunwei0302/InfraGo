import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/shared/rpc_caller.dart';

class RewardsException implements Exception {
  const RewardsException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

enum RewardTransactionType { demoGrant, earn, redeem, restore }

class RewardTransaction {
  const RewardTransaction({
    required this.id,
    required this.userId,
    required this.type,
    required this.points,
    required this.balanceAfter,
    required this.createdAt,
    this.rideId,
    this.paymentId,
  });

  factory RewardTransaction.fromRow(Map<String, dynamic> row) {
    final rawType = row['type']?.toString() ?? '';
    final RewardTransactionType type;
    switch (rawType) {
      case 'demo_grant':
        type = RewardTransactionType.demoGrant;
      case 'earn':
        type = RewardTransactionType.earn;
      case 'redeem':
        type = RewardTransactionType.redeem;
      case 'restore':
        type = RewardTransactionType.restore;
      default:
        throw ArgumentError.value(rawType, 'type', 'Unknown reward type');
    }
    return RewardTransaction(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      type: type,
      points: (row['points'] as num).toInt(),
      balanceAfter: (row['balance_after'] as num).toInt(),
      createdAt: DateTime.parse(row['created_at'] as String),
      rideId: row['ride_id'] as String?,
      paymentId: row['payment_id'] as String?,
    );
  }

  final String id;
  final String userId;
  final RewardTransactionType type;
  final int points;
  final int balanceAfter;
  final DateTime createdAt;
  final String? rideId;
  final String? paymentId;
}

typedef RewardRowsSelector = Future<List<Map<String, dynamic>>> Function(
  String table, {
  required String orderColumn,
  required bool ascending,
  int? limit,
});

class RewardsRepository {
  RewardsRepository(
    SupabaseClient client, {
    RpcCaller? rpcCaller,
    RewardRowsSelector? selectRows,
  })  : _rpc = rpcCaller ?? client.rpc,
        _selectRows = selectRows ??
            ((table, {required orderColumn, required ascending, limit}) async {
              dynamic query = client
                  .from(table)
                  .select()
                  .order(orderColumn, ascending: ascending);
              if (limit != null) {
                query = query.limit(limit);
              }
              return List<Map<String, dynamic>>.from(await query);
            });

  final RpcCaller _rpc;
  final RewardRowsSelector _selectRows;

  Future<int> ensureRewardAccount() async {
    final result = await _rpc('ensure_reward_account');
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw RewardsException(
        map['reason']?.toString() ?? 'reward_account_unavailable',
      );
    }
    return (map['points_balance'] as num).toInt();
  }

  /// Points are computed server-side from the payment's own final_amount —
  /// this never sends a client-supplied point value, and the RPC always
  /// credits the ride's rider regardless of which participant (rider or
  /// driver) happens to be the one calling it after settling payment.
  Future<void> earnCompletionReward({
    required String rideId,
    required String paymentId,
  }) async {
    if (rideId.isEmpty || paymentId.isEmpty) {
      throw const RewardsException('invalid_parameters');
    }
    final result = await _rpc(
      'earn_completion_reward',
      params: {
        'p_ride_id': rideId,
        'p_payment_id': paymentId,
      },
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['success'] != true) {
      throw RewardsException(
        map['reason']?.toString() ?? 'earn_failed',
      );
    }
  }

  Future<void> reserveRewardPoints({
    required String userId,
    required int points,
    required String rideId,
    required String paymentId,
  }) async {
    if (points <= 0) return;
    try {
      await _rpc(
        'redeem_reward_points',
        params: {
          'p_user_id': userId,
          'p_points': points,
          'p_ride_id': rideId,
          'p_payment_id': paymentId,
        },
      );
    } catch (error) {
      final msg = error.toString();
      if (msg.contains('insufficient_reward_points')) {
        throw const RewardsException('insufficient_reward_points');
      }
      throw RewardsException('reserve_failed: $error');
    }
  }

  Future<void> releaseRewardPoints({
    required String userId,
    required int points,
    required String rideId,
    required String paymentId,
  }) async {
    if (points <= 0) return;
    try {
      await _rpc(
        'restore_reward_points',
        params: {
          'p_user_id': userId,
          'p_points': points,
          'p_ride_id': rideId,
          'p_payment_id': paymentId,
        },
      );
    } catch (error) {
      throw RewardsException('release_failed: $error');
    }
  }

  Future<List<RewardTransaction>> fetchTransactionHistory({int limit = 50}) async {
    final rows = await _selectRows(
      'reward_transactions',
      orderColumn: 'created_at',
      ascending: false,
      limit: limit,
    );
    return rows.map(RewardTransaction.fromRow).toList(growable: false);
  }
}
