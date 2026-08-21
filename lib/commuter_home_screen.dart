import 'package:flutter/material.dart';

import 'analytics_screen.dart';
import 'app_theme.dart';
import 'booking_form_screen.dart';
import 'chat_with_driver_screen.dart';
import 'ride.dart';
import 'supabase_config.dart';
import 'user_profile_screen.dart';

class CommuterHomeScreen extends StatefulWidget {
  const CommuterHomeScreen({super.key});

  @override
  State<CommuterHomeScreen> createState() => _CommuterHomeScreenState();
}

class _CommuterHomeScreenState extends State<CommuterHomeScreen> {
  int _selectedIndex = 0;

  static const List<Widget> _pages = [
    _TripPlannerTab(),
    ChatWithDriverScreen(),
    AnalyticsScreen(),
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
          BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Map'),
          BottomNavigationBarItem(icon: Icon(Icons.chat), label: 'Chat'),
          BottomNavigationBarItem(icon: Icon(Icons.analytics), label: 'Analytics'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

class _TripPlannerTab extends StatelessWidget {
  const _TripPlannerTab();

  void _openBookingSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => const BookingFormSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final riderId = supabase.auth.currentUser!.id;

    return Scaffold(
      appBar: AppBar(title: const Text('InfraGo · Commuter')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.marginMobile),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 240,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: const Text('Map View'),
            ),
            const SizedBox(height: AppSpacing.md),
            StreamBuilder<List<Map<String, dynamic>>>(
              stream: supabase
                  .from('rides')
                  .stream(primaryKey: ['id'])
                  .eq('rider_id', riderId)
                  .order('created_at'),
              builder: (context, snapshot) {
                final rides = (snapshot.data ?? [])
                    .map(Ride.fromJson)
                    .where((ride) => ride.status != 'completed' && ride.status != 'cancelled')
                    .toList();
                if (rides.isEmpty) {
                  return const SizedBox.shrink();
                }
                final activeRide = rides.last;
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.gutter),
                    child: Text('Trip status: ${activeRide.status}'),
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton(
              onPressed: () => _openBookingSheet(context),
              child: const Text('Book a Ride'),
            ),
          ],
        ),
      ),
    );
  }
}
