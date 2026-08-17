import 'package:flutter/material.dart';

import 'app_theme.dart';

class AnalyticsScreen extends StatelessWidget {
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Analytics Dashboard')),
      body: const Padding(
        padding: EdgeInsets.all(AppSpacing.marginMobile),
        child: Text(
          'Open data from data.gov.my (vehicle registrations, transit '
          'ridership, fuel prices, GTFS positions) will be shown here.',
        ),
      ),
    );
  }
}
