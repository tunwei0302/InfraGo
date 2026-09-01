import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:infra_go/shared/app_state.dart';
import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/shared/supabase_config.dart';
import 'package:infra_go/foo/trip_history_screen.dart';
import 'package:infra_go/tey/driver_rating_repository.dart';
import 'package:infra_go/tey/rewards_repository.dart';
import 'package:infra_go/tey/rewards_screen.dart';

class UserProfileScreen extends StatefulWidget {
  const UserProfileScreen({super.key});

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  Map<String, dynamic>? _profile;
  bool _isLoading = true;
  bool _loadFailed = false;

  int? _rewardBalance;
  DriverRatingSummary? _driverRating;
  String? _identityStatus;
  String? _vehicleApproval;
  int? _vehicleCapacity;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() {
      _isLoading = true;
      _loadFailed = false;
    });
    final user = supabase.auth.currentUser;
    if (user == null) {
      setState(() => _isLoading = false);
      return;
    }
    try {
      final profileF = supabase
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();
      final rewardsF = RewardsRepository(supabase).ensureRewardAccount();
      final results = await Future.wait<Object?>([
        profileF,
        rewardsF,
        _loadDriverStatuses(user.id),
      ], eagerError: false);
      if (!mounted) return;
      setState(() {
        final p = results[0];
        _profile = p is Map<String, dynamic> ? p : null;
        final r = results[1];
        if (r is int) _rewardBalance = r;
        final dr = results[2];
        if (dr is _DriverStatusResult) {
          _driverRating = dr.rating;
          _identityStatus = dr.identityStatus;
          _vehicleApproval = dr.vehicleApproval;
          _vehicleCapacity = dr.vehicleCapacity;
        }
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadFailed = true;
        _isLoading = false;
      });
    }
  }

  Future<_DriverStatusResult?> _loadDriverStatuses(String userId) async {
    final role = (_profile?['role'] as String?)?.toLowerCase();
    final ratingRepo = DriverRatingRepository(supabase);
    DriverRatingSummary? rating;
    String? identityStatus;
    String? vehicleApproval;
    int? vehicleCapacity;
    try {
      final parallel = await Future.wait<Object?>([
        ratingRepo.fetchDriverSummary(userId).catchError((_) => null),
        supabase
            .from('driver_verifications')
            .select()
            .eq('driver_id', userId)
            .maybeSingle()
            .catchError((_) => null),
        supabase
            .from('driver_vehicles')
            .select()
            .eq('driver_id', userId)
            .maybeSingle()
            .catchError((_) => null),
      ], eagerError: false);
      final r = parallel[0];
      if (r is DriverRatingSummary) rating = r;
      final ver = parallel[1] as Map<String, dynamic>?;
      if (ver != null) identityStatus = ver['status']?.toString();
      final veh = parallel[2] as Map<String, dynamic>?;
      if (veh != null) {
        vehicleApproval = veh['approval_status']?.toString();
        vehicleCapacity = (veh['passenger_capacity'] as num?)?.toInt();
      }
    } catch (_) {
      // Driver-only tables gracefully fall back to null for riders
    }
    if (role != 'driver' &&
        rating == null &&
        identityStatus == null &&
        vehicleApproval == null) {
      return null;
    }
    return _DriverStatusResult(
      rating: rating,
      identityStatus: identityStatus,
      vehicleApproval: vehicleApproval,
      vehicleCapacity: vehicleCapacity,
    );
  }

  String _formatRole(String? role) {
    if (role == null || role.isEmpty) return '-';
    return role[0].toUpperCase() + role.substring(1).toLowerCase();
  }

  Color _statusColor(String? status, ColorScheme scheme) {
    switch (status) {
      case 'approved':
        return scheme.primary;
      case 'pending':
        return scheme.tertiary;
      case 'rejected':
        return scheme.error;
      default:
        return scheme.onSurfaceVariant;
    }
  }

  String _statusLabel(String? status, String fallback) {
    switch (status) {
      case 'approved':
        return 'Approved';
      case 'pending':
        return 'Pending review';
      case 'rejected':
        return 'Rejected';
      default:
        return fallback;
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = supabase.auth.currentUser?.email ?? '-';
    final scheme = Theme.of(context).colorScheme;
    final role = (_profile?['role'] as String?)?.toLowerCase();
    final isDriver = role == 'driver';

    return Scaffold(
      appBar: AppBar(
        title: const Text('User Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _loadAll,
          ),
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
                        onPressed: _loadAll,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadAll,
                  child: ListView(
                    padding: const EdgeInsets.all(AppSpacing.marginMobile),
                    children: [
                      Row(
                        children: [
                          const CircleAvatar(
                              radius: 40, child: Icon(Icons.person, size: 40)),
                          const SizedBox(width: AppSpacing.gutter),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _profile?['name'] as String? ?? '-',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: AppSpacing.xs),
                                Text(email),
                                const SizedBox(height: AppSpacing.xs),
                                Text(
                                  'Role: ${_formatRole(_profile?['role'] as String?)}',
                                  style: AppTextStyles.labelCaps,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Row(
                        children: [
                          Expanded(
                            child: _SmallStatCard(
                              label: 'Reward points',
                              value: _rewardBalance == null ? '…' : '$_rewardBalance',
                              icon: Icons.card_giftcard_outlined,
                              highlight: scheme.primaryContainer,
                              onHighlight: scheme.onPrimaryContainer,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: _SmallStatCard(
                              label: 'Driver rating',
                              value: _driverRating?.displayAverage ??
                                  'No ratings yet',
                              icon: Icons.star_border_outlined,
                              highlight: scheme.tertiaryContainer,
                              onHighlight: scheme.onTertiaryContainer,
                            ),
                          ),
                        ],
                      ),
                      if (isDriver) ...[
                        const SizedBox(height: AppSpacing.lg),
                        Text('Driver onboarding', style: AppTextStyles.sectionHeader),
                        const SizedBox(height: AppSpacing.md),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.gutter),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _StatusRow(
                                  label: 'Identity (licence + selfie)',
                                  status: _identityStatus,
                                  fallback: 'Not submitted',
                                  colorScheme: scheme,
                                  statusColor: _statusColor,
                                  statusLabel: _statusLabel,
                                ),
                                const Divider(height: AppSpacing.lg),
                                _StatusRow(
                                  label: 'Vehicle registration',
                                  status: _vehicleApproval,
                                  fallback: 'Not submitted',
                                  subtitle: _vehicleCapacity != null
                                      ? 'Capacity: $_vehicleCapacity pax'
                                      : null,
                                  colorScheme: scheme,
                                  statusColor: _statusColor,
                                  statusLabel: _statusLabel,
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_vehicleApproval?.toLowerCase() == 'pending' &&
                            (_vehicleCapacity ?? 0) < 6)
                          Padding(
                            padding: const EdgeInsets.only(
                                top: AppSpacing.sm,
                                left: AppSpacing.md,
                                right: AppSpacing.md),
                            child: Text(
                              'Note: 6-Seater service requires registered passenger capacity of at least 6.',
                              style: TextStyle(
                                  color: scheme.error,
                                  fontStyle: FontStyle.italic),
                            ),
                          ),
                      ],
                      const SizedBox(height: AppSpacing.lg),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const RewardsScreen()),
                                );
                              },
                              icon: const Icon(Icons.card_giftcard),
                              label: const Text('View Rewards'),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          const TripHistoryScreen()),
                              );
                              },
                              icon: const Icon(Icons.history),
                              label: const Text('Trip History'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Text('AI Disclosure (coursework)',
                          style: AppTextStyles.labelCaps),
                      const SizedBox(height: AppSpacing.xs),
                      const Text(
                        'AI tools assisted code layout, SQL migration templates and '
                        'repository patterns in this module. All RLS policies, status '
                        'gates, handoff contracts and wording were manually reviewed '
                        'against the shared team contract before submission. Known '
                        'limitations: prototype calculations use coursework-formula '
                        'pricing; no real card/bank data is collected; driver/vehicle '
                        'approval reflects submitted info only, not government '
                        'ownership verification.',
                        softWrap: true,
                      ),
                    ],
                  ),
                ),
    );
  }
}

class _DriverStatusResult {
  const _DriverStatusResult({
    this.rating,
    this.identityStatus,
    this.vehicleApproval,
    this.vehicleCapacity,
  });
  final DriverRatingSummary? rating;
  final String? identityStatus;
  final String? vehicleApproval;
  final int? vehicleCapacity;
}

class _SmallStatCard extends StatelessWidget {
  const _SmallStatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.highlight,
    required this.onHighlight,
  });
  final String label;
  final String value;
  final IconData icon;
  final Color highlight;
  final Color onHighlight;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: highlight,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: onHighlight),
                const SizedBox(width: AppSpacing.xs),
                Text(label,
                    style: TextStyle(
                        color: onHighlight,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(value,
                style: TextStyle(
                    color: onHighlight,
                    fontWeight: FontWeight.bold,
                    fontSize: 18)),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.status,
    required this.fallback,
    required this.colorScheme,
    required this.statusColor,
    required this.statusLabel,
    this.subtitle,
  });
  final String label;
  final String? status;
  final String fallback;
  final ColorScheme colorScheme;
  final Color Function(String?, ColorScheme) statusColor;
  final String Function(String?, String) statusLabel;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppTextStyles.labelCaps),
              if (subtitle != null)
                Text(subtitle!,
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: 4),
          decoration: BoxDecoration(
            color: statusColor(status, colorScheme).withOpacity(0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            statusLabel(status, fallback),
            style: TextStyle(
                color: statusColor(status, colorScheme),
                fontWeight: FontWeight.bold,
                fontSize: 12),
          ),
        ),
      ],
    );
  }
}
