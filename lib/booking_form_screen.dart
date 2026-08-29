import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'supabase_config.dart';

class BookingFormSheet extends StatefulWidget {
  const BookingFormSheet({
    super.key,
    this.initialPickup = '',
    this.initialDestination = '',
  });

  final String initialPickup;
  final String initialDestination;

  @override
  State<BookingFormSheet> createState() => _BookingFormSheetState();
}

class _BookingFormSheetState extends State<BookingFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _pickupController;
  late final TextEditingController _destinationController;
  bool _isSubmitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _pickupController = TextEditingController(text: widget.initialPickup);
    _destinationController = TextEditingController(
      text: widget.initialDestination,
    );
  }

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
      _submitError = null;
    });
    try {
      await supabase.from('rides').insert({
        'rider_id': supabase.auth.currentUser!.id,
        'pickup': _pickupController.text.trim(),
        'destination': _destinationController.text.trim(),
        'status': 'requested',
      });
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context);
        messenger.showSnackBar(
          const SnackBar(content: Text('Ride requested successfully.')),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _submitError = 'Could not request this ride. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.marginMobile,
        right: AppSpacing.marginMobile,
        top: AppSpacing.marginMobile,
        bottom:
            MediaQuery.of(context).viewInsets.bottom + AppSpacing.marginMobile,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('CONFIRM RIDE', style: AppTextStyles.labelCaps),
            const SizedBox(height: AppSpacing.gutter),
            TextFormField(
              controller: _pickupController,
              readOnly: true,
              maxLines: 2,
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
              readOnly: true,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Destination'),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a destination';
                }
                return null;
              },
            ),
            if (_submitError != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                _submitError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            ElevatedButton(
              onPressed: _isSubmitting ? null : _submit,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Request ride'),
            ),
          ],
        ),
      ),
    );
  }
}
