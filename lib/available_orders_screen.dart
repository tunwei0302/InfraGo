import 'package:flutter/material.dart';

class AvailableOrdersScreen extends StatelessWidget {
  const AvailableOrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final orders = <String>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Available Orders')),
      body: orders.isEmpty
          ? const Center(child: Text('No orders yet'))
          : ListView.builder(
              itemCount: orders.length,
              itemBuilder: (context, index) => ListTile(
                title: Text(orders[index]),
              ),
            ),
    );
  }
}
