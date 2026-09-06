import 'dart:async';

import 'package:flutter/material.dart';

import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/tey/rewards_repository.dart';
import 'package:infra_go/shared/supabase_config.dart';

class RewardsScreen extends StatefulWidget {
  const RewardsScreen({super.key});

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen> {
  final RewardsRepository _repository = RewardsRepository(supabase);
  int? _balance;
  List<RewardTransaction> _history = const [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _repository.ensureRewardAccount(),
        _repository.fetchTransactionHistory(),
      ]);
      if (!mounted) return;
      setState(() {
        _balance = results[0] as int;
        _history = results[1] as List<RewardTransaction>;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your rewards activity.';
        _isLoading = false;
      });
    }
  }

  String _typeLabel(RewardTransactionType type) {
    switch (type) {
      case RewardTransactionType.demoGrant:
        return 'Demo grant';
      case RewardTransactionType.earn:
        return 'Ride reward';
      case RewardTransactionType.redeem:
        return 'Ride redemption';
      case RewardTransactionType.restore:
        return 'Refund restore';
    }
  }

  IconData _typeIcon(RewardTransactionType type) {
    switch (type) {
      case RewardTransactionType.demoGrant:
      case RewardTransactionType.earn:
      case RewardTransactionType.restore:
        return Icons.add_circle_outline;
      case RewardTransactionType.redeem:
        return Icons.remove_circle_outline;
    }
  }

  Color _typeColor(RewardTransactionType type, ColorScheme scheme) {
    switch (type) {
      case RewardTransactionType.demoGrant:
      case RewardTransactionType.earn:
      case RewardTransactionType.restore:
        return scheme.primary;
      case RewardTransactionType.redeem:
        return scheme.tertiary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rewards'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _load,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.marginMobile),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.gutter),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Points balance',
                            style: AppTextStyles.labelCaps,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            '${_balance ?? 0}',
                            style: AppTextStyles.statsNumeric,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            '100 points = RM1. Redeem up to 20% of a ride\'s fare at checkout.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    Card(
                      color: scheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Text(
                          _error!,
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  Text('Activity', style: AppTextStyles.sectionHeader),
                  const SizedBox(height: AppSpacing.md),
                  if (_history.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                      child: Center(child: Text('No reward activity yet.')),
                    )
                  else
                    ..._history.map(
                      (tx) => Card(
                        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: ListTile(
                          leading: Icon(
                            _typeIcon(tx.type),
                            color: _typeColor(tx.type, scheme),
                          ),
                          title: Text(_typeLabel(tx.type)),
                          subtitle: Text(
                            '${tx.createdAt.toLocal().day}/${tx.createdAt.toLocal().month}/${tx.createdAt.toLocal().year}',
                          ),
                          trailing: Text(
                            tx.points > 0 ? '+${tx.points}' : '${tx.points}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: _typeColor(tx.type, scheme),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
