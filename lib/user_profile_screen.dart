import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'app_theme.dart';
import 'rewards_screen.dart';
import 'supabase_config.dart';

class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key});

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  Map<String, dynamic>? _profile;
  bool _isLoading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      return;
    }
    setState(() {
      _isLoading = true;
      _loadFailed = false;
    });
    try {
      final data = await supabase.from('profiles').select().eq('id', user.id).single();
      setState(() {
        _profile = data;
        _isLoading = false;
      });
    } catch (_) {
      setState(() {
        _loadFailed = true;
        _isLoading = false;
      });
    }
  }

  String _formatRole(String? role) {
    if (role == null || role.isEmpty) {
      return '-';
    }
    return role[0].toUpperCase() + role.substring(1).toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final email = supabase.auth.currentUser?.email ?? '-';

    return Scaffold(
      appBar: AppBar(
        title: const Text('User Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              context.read<AppState>().signOut();
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _loadFailed
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Could not load your profile.'),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _loadProfile,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : Padding(
              padding: const EdgeInsets.all(AppSpacing.marginMobile),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const CircleAvatar(radius: 40, child: Icon(Icons.person, size: 40)),
                  const SizedBox(height: AppSpacing.md),
                  Text('Name', style: AppTextStyles.labelCaps),
                  Text(_profile?['name'] as String? ?? '-'),
                  const SizedBox(height: AppSpacing.gutter),
                  Text('Email', style: AppTextStyles.labelCaps),
                  Text(email),
                  const SizedBox(height: AppSpacing.gutter),
                  Text('Role', style: AppTextStyles.labelCaps),
                  Text(_formatRole(_profile?['role'] as String?)),
                  const SizedBox(height: AppSpacing.md),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const RewardsScreen()),
                      );
                    },
                    child: const Text('View Rewards'),
                  ),
                ],
              ),
            ),
    );
  }
}
