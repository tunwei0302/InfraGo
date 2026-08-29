import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'available_orders_screen.dart';
import 'chat_with_driver_screen.dart';
import 'payment_repository.dart';
import 'supabase_config.dart';
import 'user_profile_screen.dart';

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  int _selectedIndex = 0;

  static const List<Widget> _pages = [
    _DriverHubTab(),
    AvailableOrdersScreen(),
    ChatWithDriverScreen(title: 'Chat with Rider'),
    UserProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.local_taxi), label: 'Hub'),
          BottomNavigationBarItem(icon: Icon(Icons.list_alt), label: 'Orders'),
          BottomNavigationBarItem(icon: Icon(Icons.chat), label: 'Chat'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

class _DriverHubTab extends StatefulWidget {
  const _DriverHubTab();

  @override
  State<_DriverHubTab> createState() => _DriverHubTabState();
}

class _DriverHubTabState extends State<_DriverHubTab> {
  bool _isOnline = false;
  final PaymentRepository _paymentRepository = PaymentRepository(supabase);

  Future<void> _startRide(String rideId) async {
    await supabase.from('rides').update({'status': 'en_route'}).eq('id', rideId);
  }

  Future<void> _completeRide(BuildContext context, String rideId) async {
    await supabase.from('rides').update({'status': 'completed'}).eq('id', rideId);

    final settlements = <Future<Map<String, dynamic>>>[
      _paymentRepository.completeCashPayment(rideId),
      _paymentRepository.captureWalletPayment(rideId),
    ];
    for (final settle in settlements) {
      try {
        final result = await settle;
        final reason = result['reason']?.toString();
        if (result['success'] != true &&
            reason != 'payment_not_found' &&
            context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Payment settlement issue: $reason')),
          );
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final driverId = supabase.auth.currentUser?.id;
    return Scaffold(
      appBar: AppBar(title: const Text('InfraGo · Driver')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.marginMobile),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(_isOnline ? 'Online' : 'Offline'),
                const Expanded(child: SizedBox()),
                Switch(
                  value: _isOnline,
                  onChanged: (value) {
                    setState(() {
                      _isOnline = value;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Active ride', style: AppTextStyles.labelCaps),
            const SizedBox(height: AppSpacing.xs),
            if (driverId == null)
              const Text('Sign in as a driver to see your active ride.')
            else
              Expanded(
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: supabase
                      .from('rides')
                      .stream(primaryKey: ['id'])
                      .eq('driver_id', driverId)
                      .order('created_at'),
                  builder: (context, snapshot) {
                    final rides = (snapshot.data ?? [])
                        .where(
                          (row) =>
                              row['status'] == 'driver_assigned' ||
                              row['status'] == 'en_route',
                        )
                        .toList();
                    if (rides.isEmpty) {
                      return const Text('No active ride.');
                    }
                    final ride = rides.first;
                    final rideId = ride['id'] as String;
                    final status = ride['status'] as String;
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.gutter),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${ride['pickup']} → ${ride['destination']}'),
                            const SizedBox(height: AppSpacing.xs),
                            Text('Status: ${status.replaceAll('_', ' ')}'),
                            const SizedBox(height: AppSpacing.sm),
                            if (status == 'driver_assigned')
                              ElevatedButton(
                                onPressed: () => _startRide(rideId),
                                child: const Text('Start ride'),
                              ),
                            if (status == 'en_route')
                              ElevatedButton(
                                onPressed: () => _completeRide(context, rideId),
                                child: const Text('Complete ride'),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
