import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'available_orders_screen.dart';
import 'chat_with_driver_screen.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('InfraGo · Driver')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.marginMobile),
        child: Row(
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
      ),
    );
  }
}
