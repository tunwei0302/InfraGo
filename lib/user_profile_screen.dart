import 'package:flutter/material.dart';

import 'app_theme.dart';

class UserProfileScreen extends StatelessWidget {
  const UserProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('User Profile')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.marginMobile),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const CircleAvatar(radius: 40, child: Icon(Icons.person, size: 40)),
            const SizedBox(height: AppSpacing.md),
            Text('Name', style: AppTextStyles.labelCaps),
            const Text('-'),
            const SizedBox(height: AppSpacing.gutter),
            Text('Email', style: AppTextStyles.labelCaps),
            const Text('-'),
          ],
        ),
      ),
    );
  }
}
