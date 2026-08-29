import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'driver_rating_screen.dart';
import 'receipt_repository.dart';
import 'supabase_config.dart';

String _formatServiceType(String value) {
  switch (value) {
    case 'economy_4':
      return 'Economy';
    case 'six_seater':
      return 'SUV / 6-seater';
    case 'shared_economy':
      return 'Shared Economy';
    default:
      return value;
  }
}

String _formatStatus(String value) => value.replaceAll('_', ' ');

String _formatDate(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')} '
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

class ReceiptScreen extends StatefulWidget {
  const ReceiptScreen({super.key, required this.rideId});

  final String rideId;

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  final ReceiptRepository _repository = ReceiptRepository(supabase);
  ReceiptData? _receipt;
  bool _isRated = true;
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
      final receipt = await _repository.loadReceipt(widget.rideId);
      final rated = receipt.status == 'completed'
          ? await _repository.hasRating(widget.rideId)
          : true;
      if (!mounted) return;
      setState(() {
        _receipt = receipt;
        _isRated = rated;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load this receipt.';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receipt')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : _buildBody(context, _receipt!),
    );
  }

  Widget _buildBody(BuildContext context, ReceiptData receipt) {
    final quote = receipt.fareQuote;
    final payment = receipt.payment;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.marginMobile),
      children: [
        Text('Route', style: AppTextStyles.labelCaps),
        const SizedBox(height: AppSpacing.xs),
        Text(receipt.pickupLabel, style: Theme.of(context).textTheme.bodyMedium),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Icon(Icons.arrow_downward, size: 16),
        ),
        Text(
          receipt.destinationLabel,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.md),
        Text('Category', style: AppTextStyles.labelCaps),
        const SizedBox(height: AppSpacing.xs),
        Text(_formatServiceType(receipt.serviceType)),
        const SizedBox(height: AppSpacing.md),
        Text('Status', style: AppTextStyles.labelCaps),
        const SizedBox(height: AppSpacing.xs),
        Text(_formatStatus(receipt.status)),
        const SizedBox(height: AppSpacing.md),
        if (quote != null) ...[
          Text('Fare breakdown', style: AppTextStyles.labelCaps),
          const SizedBox(height: AppSpacing.xs),
          _row(
            'Base fare (${quote.pricingVersion})',
            '${quote.currency} ${quote.baseAmount.toStringAsFixed(2)}',
          ),
          _row('Vehicle multiplier', '×${quote.vehicleMultiplier.toStringAsFixed(2)}'),
          if (quote.sharedAmount != null)
            _row(
              'Shared fare (if matched)',
              '${quote.currency} ${quote.sharedAmount!.toStringAsFixed(2)}',
            ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (payment != null) ...[
          Text('Payment', style: AppTextStyles.labelCaps),
          const SizedBox(height: AppSpacing.xs),
          _row('Method', payment.method == 'cash' ? 'Cash' : 'Demo Wallet'),
          _row('Status', _formatStatus(payment.status)),
          _row(
            'Quoted amount',
            '${payment.currency} ${payment.quotedAmount.toStringAsFixed(2)}',
          ),
          if (payment.discountAmount > 0)
            _row(
              'Discount (${payment.rewardPointsRedeemed} points)',
              '-${payment.currency} ${payment.discountAmount.toStringAsFixed(2)}',
            ),
          if (payment.cancellationFee > 0)
            _row(
              'Cancellation fee',
              '${payment.currency} ${payment.cancellationFee.toStringAsFixed(2)}',
            ),
          if (payment.refundedAmount > 0)
            _row(
              'Refunded',
              '${payment.currency} ${payment.refundedAmount.toStringAsFixed(2)}',
            ),
          if (payment.finalAmount != null)
            _row(
              'Final amount',
              '${payment.currency} ${payment.finalAmount!.toStringAsFixed(2)}',
            ),
          _row('Updated', _formatDate(payment.updatedAt)),
          const SizedBox(height: AppSpacing.md),
        ],
        if (receipt.cancelledAt != null) ...[
          Text('Cancelled', style: AppTextStyles.labelCaps),
          const SizedBox(height: AppSpacing.xs),
          _row('Date', _formatDate(receipt.cancelledAt!)),
          if (receipt.cancellationReason != null)
            _row('Reason', receipt.cancellationReason!),
          const SizedBox(height: AppSpacing.md),
        ],
        if (receipt.status == 'completed' &&
            !_isRated &&
            receipt.driverId != null)
          ElevatedButton(
            onPressed: () async {
              final rated = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (context) => DriverRatingScreen(
                    rideId: receipt.rideId,
                    driverId: receipt.driverId!,
                  ),
                ),
              );
              if (rated == true && mounted) unawaited(_load());
            },
            child: const Text('Rate your driver'),
          ),
      ],
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value, style: Theme.of(context).textTheme.bodyMedium),
      ],
    ),
  );
}
