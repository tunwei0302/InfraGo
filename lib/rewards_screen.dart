import 'package:flutter/material.dart';

import 'app_theme.dart';

class RewardsScreen extends StatelessWidget {
  const RewardsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rewards')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.marginMobile),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Points', style: AppTextStyles.labelCaps),
            const SizedBox(height: AppSpacing.xs),
            Text('0', style: AppTextStyles.statsNumeric),
          ],
        ),
      ),
    );
  }
}
