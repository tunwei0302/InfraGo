import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'rewards_screen.dart';

class BookingFormScreen extends StatefulWidget {
  const BookingFormScreen({super.key});

  @override
  State<BookingFormScreen> createState() => _BookingFormScreenState();
}

class _BookingFormScreenState extends State<BookingFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _pickupController = TextEditingController();
  final _destinationController = TextEditingController();

  @override
  void dispose() {
    _pickupController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ride Booking & Forms')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.marginMobile),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                onPressed: _submit,
                child: const Text('Confirm Booking'),
              ),
              const SizedBox(height: AppSpacing.base),
              ElevatedButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const RewardsScreen()),
                  );
                },
                child: const Text('View Rewards'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
