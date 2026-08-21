import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'supabase_config.dart';

class BookingFormSheet extends StatefulWidget {
  const BookingFormSheet({super.key});

  @override
  State<BookingFormSheet> createState() => _BookingFormSheetState();
}

class _BookingFormSheetState extends State<BookingFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _pickupController = TextEditingController();
  final _destinationController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _pickupController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _isSubmitting = true;
    });
    await supabase.from('rides').insert({
      'rider_id': supabase.auth.currentUser!.id,
      'pickup': _pickupController.text.trim(),
      'destination': _destinationController.text.trim(),
      'status': 'requested',
    });
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.marginMobile,
        right: AppSpacing.marginMobile,
        top: AppSpacing.marginMobile,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.marginMobile,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Ride Booking & Forms', style: AppTextStyles.labelCaps),
            const SizedBox(height: AppSpacing.gutter),
            TextFormField(
              controller: _pickupController,
              decoration: const InputDecoration(labelText: 'Pickup location'),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a pickup location';
                }
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.gutter),
            TextFormField(
              controller: _destinationController,
              decoration: const InputDecoration(labelText: 'Destination'),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a destination';
                }
                return null;
              },
            ),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton(
              onPressed: _isSubmitting ? null : _submit,
              child: const Text('Confirm Booking'),
            ),
          ],
        ),
      ),
    );
  }
}
