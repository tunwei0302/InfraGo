import 'package:flutter/material.dart';

import 'package:infra_go/foo/payment_repository.dart';
import 'package:infra_go/shared/ride.dart';
import 'package:infra_go/shared/supabase_config.dart';

class AvailableOrdersScreen extends StatelessWidget {
  const AvailableOrdersScreen({super.key});

  Future<void> _acceptRide(BuildContext context, Ride ride) async {
    await supabase
        .from('rides')
        .update({
          'driver_id': supabase.auth.currentUser!.id,
          'status': 'driver_assigned',
          'accepted_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', ride.id);

    try {
      final result = await PaymentRepository(
        supabase,
      ).authoriseWalletPayment(ride.id);
      if (result['success'] != true &&
          result['reason'] != 'payment_not_found' &&
          context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Wallet reserve failed: ${result['reason']}'),
          ),
        );
      }
    } catch (_) {
      // Cash rides and any other non-wallet payment methods reach this
      // path harmlessly; the ride is already accepted regardless.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Available Orders')),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: supabase
            .from('rides')
            .stream(primaryKey: ['id'])
            .eq('status', 'requested')
            .order('created_at'),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final orders = snapshot.data!.map(Ride.fromJson).toList();
          if (orders.isEmpty) {
            return const Center(child: Text('No orders yet'));
          }
          return ListView.builder(
            itemCount: orders.length,
            itemBuilder: (context, index) {
              final order = orders[index];
              return ListTile(
                title: Text('${order.pickup} → ${order.destination}'),
                trailing: ElevatedButton(
                  onPressed: () => _acceptRide(context, order),
                  child: const Text('Accept'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
