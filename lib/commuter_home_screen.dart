import 'package:flutter/material.dart';

import 'analytics_screen.dart';
import 'chat_with_driver_screen.dart';
import 'trip_planner_map_screen.dart';
import 'user_profile_screen.dart';

class CommuterHomeScreen extends StatefulWidget {
  const CommuterHomeScreen({super.key});

  @override
  State<CommuterHomeScreen> createState() => _CommuterHomeScreenState();
}

class _CommuterHomeScreenState extends State<CommuterHomeScreen> {
  int _selectedIndex = 0;

  static const List<Widget> _pages = [
    TripPlannerMapScreen(),
    ChatWithDriverScreen(),
    AnalyticsScreen(),
    UserProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _pages),
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
          BottomNavigationBarItem(
            icon: Icon(Icons.analytics),
            label: 'Analytics',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}
