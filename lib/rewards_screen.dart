import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'rewards_repository.dart';
import 'supabase_config.dart';

class RewardsScreen extends StatefulWidget {
  const RewardsScreen({super.key});

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen> {
  final RewardsRepository _repository = RewardsRepository(supabase);
  int? _balance;
  bool _isLoading = true;
  bool _isGranting = false;
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
      final balance = await _repository.ensureRewardAccount();
      if (!mounted) return;
      setState(() {
        _balance = balance;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your rewards balance.';
        _isLoading = false;
      });
    }
  }

  Future<void> _grantDemoPoints() async {
    setState(() => _isGranting = true);
    try {
      final balance = await _repository.demoGrant(100);
      if (!mounted) return;
      setState(() => _balance = balance);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not add demo points: $error');
    } finally {
      if (mounted) setState(() => _isGranting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rewards')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.marginMobile),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Points', style: AppTextStyles.labelCaps),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _isLoading ? '…' : '${_balance ?? 0}',
              style: AppTextStyles.statsNumeric,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '100 points = RM1. Redeem up to 20% of a ride\'s fare at checkout.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            OutlinedButton(
              onPressed: _isGranting ? null : _grantDemoPoints,
              child: Text(
                _isGranting ? 'Adding…' : 'Add 100 demo points',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
