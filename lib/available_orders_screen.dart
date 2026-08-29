import 'package:flutter/material.dart';

import 'ride.dart';
import 'supabase_config.dart';

class AvailableOrdersScreen extends StatelessWidget {
  const AvailableOrdersScreen({super.key});

  Future<void> _acceptRide(Ride ride) async {
    await supabase
        .from('rides')
        .update({
          'driver_id': supabase.auth.currentUser!.id,
          'status': 'driver_assigned',
        })
        .eq('id', ride.id);
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
                  onPressed: () => _acceptRide(order),
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
