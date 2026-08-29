import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'payment_method.dart';
import 'payment_repository.dart';

class CheckoutSheet extends StatefulWidget {
  const CheckoutSheet({
    super.key,
    required this.amount,
    required this.currency,
    required this.paymentRepository,
  });

  final double amount;
  final String currency;
  final PaymentRepository paymentRepository;

  static Future<PaymentMethod?> show(
    BuildContext context, {
    required double amount,
    required String currency,
    required PaymentRepository paymentRepository,
  }) {
    return showModalBottomSheet<PaymentMethod>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => CheckoutSheet(
        amount: amount,
        currency: currency,
        paymentRepository: paymentRepository,
      ),
    );
  }

  @override
  State<CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends State<CheckoutSheet> {
  PaymentMethod _method = PaymentMethod.cash;
  double? _walletBalance;
  bool _isLoadingBalance = true;
  bool _isToppingUp = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBalance());
  }

  Future<void> _loadBalance() async {
    try {
      final result = await widget.paymentRepository.ensureWalletAccount();
      if (!mounted) return;
      setState(() {
        _walletBalance = (result['balance'] as num?)?.toDouble() ?? 0;
        _isLoadingBalance = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _walletBalance = null;
        _isLoadingBalance = false;
      });
    }
  }

  Future<void> _topUp() async {
    setState(() {
      _isToppingUp = true;
      _error = null;
    });
    try {
      final result = await widget.paymentRepository.topUpDemoWallet(50);
      if (!mounted) return;
      setState(() {
        _walletBalance = (result['balance'] as num?)?.toDouble() ?? _walletBalance;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Top-up failed: $error');
    } finally {
      if (mounted) setState(() => _isToppingUp = false);
    }
  }

  bool get _walletInsufficient =>
      _method == PaymentMethod.demoWallet &&
      _walletBalance != null &&
      _walletBalance! < widget.amount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.gutter,
        right: AppSpacing.gutter,
        top: AppSpacing.gutter,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.gutter,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            Text('Checkout', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Amount due: ${widget.currency} ${widget.amount.toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text(
              'Coursework estimate. Not a real charge.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: AppSpacing.md),
            RadioGroup<PaymentMethod>(
              groupValue: _method,
              onChanged: (value) => setState(() => _method = value!),
              child: Column(
                children: [
                  RadioListTile<PaymentMethod>(
                    value: PaymentMethod.cash,
                    title: const Text('Cash'),
                    subtitle: const Text(
                      'Pay the driver when the ride completes',
                    ),
                  ),
                  RadioListTile<PaymentMethod>(
                    value: PaymentMethod.demoWallet,
                    title: const Text('Coursework Demo Wallet'),
                    subtitle: _isLoadingBalance
                        ? const Text('Loading balance…')
                        : Text(
                            _walletBalance == null
                                ? 'Balance unavailable'
                                : 'Balance: ${widget.currency} ${_walletBalance!.toStringAsFixed(2)}',
                          ),
                  ),
                ],
              ),
            ),
            if (_method == PaymentMethod.demoWallet) ...[
              const SizedBox(height: AppSpacing.xs),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _isToppingUp ? null : _topUp,
                  child: Text(
                    _isToppingUp ? 'Adding funds…' : 'Add RM50 demo funds',
                  ),
                ),
              ),
              if (_walletInsufficient)
                Text(
                  'Insufficient demo balance for this ride.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            ElevatedButton(
              onPressed: _walletInsufficient
                  ? null
                  : () => Navigator.of(context).pop(_method),
              child: const Text('Confirm payment method'),
            ),
          ],
        ),
      ),
    );
  }
}
