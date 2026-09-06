import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:infra_go/shared/app_state.dart';
import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/shared/supabase_config.dart';
import 'package:infra_go/tey/admin_review_repository.dart';

class AdminProfileScreen extends StatefulWidget {
  const AdminProfileScreen({super.key});

  @override
  State<AdminProfileScreen> createState() => _AdminProfileScreenState();
}

class _AdminProfileScreenState extends State<AdminProfileScreen>
    with SingleTickerProviderStateMixin {
  final AdminReviewRepository _repo = AdminReviewRepository(supabase);
  late final TabController _tabs;

  Map<String, dynamic>? _profile;
  bool _loadingProfile = true;

  List<PendingIdentitySubmission> _identities = const [];
  List<PendingVehicleSubmission> _vehicles = const [];
  bool _loadingIdentities = true;
  bool _loadingVehicles = true;
  String? _identityError;
  String? _vehicleError;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _loadProfile();
    _loadIdentities();
    _loadVehicles();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      setState(() => _loadingProfile = false);
      return;
    }
    try {
      final row = await supabase
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();
      if (!mounted) return;
      setState(() {
        _profile = row;
        _loadingProfile = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingProfile = false);
    }
  }

  Future<void> _loadIdentities() async {
    setState(() {
      _loadingIdentities = true;
      _identityError = null;
    });
    try {
      final rows = await _repo.fetchPendingIdentities();
      if (!mounted) return;
      setState(() {
        _identities = rows;
        _loadingIdentities = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _identityError = 'Could not load identity queue: $error';
        _loadingIdentities = false;
      });
    }
  }

  Future<void> _loadVehicles() async {
    setState(() {
      _loadingVehicles = true;
      _vehicleError = null;
    });
    try {
      final rows = await _repo.fetchPendingVehicles();
      if (!mounted) return;
      setState(() {
        _vehicles = rows;
        _loadingVehicles = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _vehicleError = 'Could not load vehicle queue: $error';
        _loadingVehicles = false;
      });
    }
  }

  Future<void> _approveIdentity(PendingIdentitySubmission s) async {
    try {
      await _repo.approveIdentity(s.driverId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Approved identity for ${s.driverName}')),
      );
      unawaited(_loadIdentities());
    } on AdminReviewException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
    }
  }

  Future<void> _rejectIdentity(PendingIdentitySubmission s) async {
    final reason = await _promptForReason(
      title: 'Reject identity for ${s.driverName}',
      hint: 'Explain why this identity submission is being rejected.',
    );
    if (reason == null || reason.trim().length < 2) return;
    try {
      await _repo.rejectIdentity(driverId: s.driverId, reason: reason.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rejected identity for ${s.driverName}')),
      );
      unawaited(_loadIdentities());
    } on AdminReviewException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
    }
  }

  Future<void> _approveVehicle(PendingVehicleSubmission s) async {
    try {
      await _repo.approveVehicle(s.driverId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Approved vehicle for ${s.driverName}')),
      );
      unawaited(_loadVehicles());
    } on AdminReviewException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
    }
  }

  Future<void> _rejectVehicle(PendingVehicleSubmission s) async {
    final reason = await _promptForReason(
      title: 'Reject vehicle for ${s.driverName}',
      hint: 'Explain why this vehicle submission is being rejected.',
    );
    if (reason == null || reason.trim().length < 2) return;
    try {
      await _repo.rejectVehicle(driverId: s.driverId, reason: reason.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rejected vehicle for ${s.driverName}')),
      );
      unawaited(_loadVehicles());
    } on AdminReviewException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
    }
  }

  Future<String?> _promptForReason({
    required String title,
    required String hint,
  }) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLines: 3,
          minLines: 2,
          maxLength: 500,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () {
              FocusScope.of(context).unfocus();
              Navigator.of(context).pop(null);
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              FocusScope.of(context).unfocus();
              Navigator.of(context).pop(controller.text);
            },
            child: const Text('Submit reason'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final email = supabase.auth.currentUser?.email ?? '-';
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _loadProfile();
              _loadIdentities();
              _loadVehicles();
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              context.read<AppState>().signOut();
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: scheme.onPrimary,
          unselectedLabelColor: scheme.onPrimary.withValues(alpha: 0.7),
          indicatorColor: scheme.onPrimary,
          tabs: [
            Tab(
              icon: const Icon(Icons.badge_outlined),
              text: 'Identity (${_identities.length})',
            ),
            Tab(
              icon: const Icon(Icons.directions_car_outlined),
              text: 'Vehicle (${_vehicles.length})',
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.marginMobile),
            child: Row(
              children: [
                const CircleAvatar(
                  radius: 32,
                  child: Icon(Icons.admin_panel_settings, size: 32),
                ),
                const SizedBox(width: AppSpacing.gutter),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _loadingProfile
                            ? 'Loading…'
                            : (_profile?['name'] as String? ?? 'Admin'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(email),
                      const SizedBox(height: AppSpacing.xs),
                      Text('Role: Admin', style: AppTextStyles.labelCaps),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                RefreshIndicator(
                  onRefresh: _loadIdentities,
                  child: _IdentityQueueBody(
                    loading: _loadingIdentities,
                    error: _identityError,
                    items: _identities,
                    onApprove: _approveIdentity,
                    onReject: _rejectIdentity,
                    onRetry: _loadIdentities,
                    scheme: scheme,
                  ),
                ),
                RefreshIndicator(
                  onRefresh: _loadVehicles,
                  child: _VehicleQueueBody(
                    loading: _loadingVehicles,
                    error: _vehicleError,
                    items: _vehicles,
                    onApprove: _approveVehicle,
                    onReject: _rejectVehicle,
                    onRetry: _loadVehicles,
                    scheme: scheme,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IdentityQueueBody extends StatelessWidget {
  const _IdentityQueueBody({
    required this.loading,
    required this.error,
    required this.items,
    required this.onApprove,
    required this.onReject,
    required this.onRetry,
    required this.scheme,
  });

  final bool loading;
  final String? error;
  final List<PendingIdentitySubmission> items;
  final void Function(PendingIdentitySubmission) onApprove;
  final void Function(PendingIdentitySubmission) onReject;
  final VoidCallback onRetry;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Card(
                color: scheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Text(
                    error!,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text('No pending identity submissions. Nice work!'),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.marginMobile),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final s = items[index];
        return Card(
          margin: const EdgeInsets.only(bottom: AppSpacing.md),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.badge_outlined),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        s.driverName,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Contact: ${s.contact}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  'Submitted: ${s.submittedAt.toLocal().day}/${s.submittedAt.toLocal().month}/${s.submittedAt.toLocal().year}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Manual review only. InfraGo does not perform face recognition or eKYC.',
                  style: TextStyle(color: scheme.primary, fontSize: 12),
                ),
                const SizedBox(height: AppSpacing.gutter),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => onReject(s),
                      child: const Text('Reject'),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    ElevatedButton(
                      onPressed: () => onApprove(s),
                      child: const Text('Approve'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _VehicleQueueBody extends StatelessWidget {
  const _VehicleQueueBody({
    required this.loading,
    required this.error,
    required this.items,
    required this.onApprove,
    required this.onReject,
    required this.onRetry,
    required this.scheme,
  });

  final bool loading;
  final String? error;
  final List<PendingVehicleSubmission> items;
  final void Function(PendingVehicleSubmission) onApprove;
  final void Function(PendingVehicleSubmission) onReject;
  final VoidCallback onRetry;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Card(
                color: scheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Text(
                    error!,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: Text('No pending vehicle submissions. Nice work!'),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.marginMobile),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final s = items[index];
        return Card(
          margin: const EdgeInsets.only(bottom: AppSpacing.md),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.directions_car_outlined),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        s.driverName,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (s.requestsSixSeater)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: s.passengerCapacity >= 6
                              ? scheme.primaryContainer
                              : scheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          s.passengerCapacity >= 6
                              ? '6-Seater eligible'
                              : '6-Seater ⚠ capacity=${s.passengerCapacity}',
                          style: TextStyle(
                            color: s.passengerCapacity >= 6
                                ? scheme.onPrimaryContainer
                                : scheme.onErrorContainer,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.gutter,
                  runSpacing: AppSpacing.xs,
                  children: [
                    _InfoChip(label: 'Make', value: s.make),
                    _InfoChip(label: 'Model', value: s.model),
                    _InfoChip(label: 'Colour', value: s.color),
                    _InfoChip(label: 'Body', value: s.bodyType),
                    _InfoChip(label: 'Plate', value: s.plateNumber),
                    _InfoChip(
                      label: 'Capacity',
                      value: '${s.passengerCapacity} pax',
                    ),
                    _InfoChip(
                      label: 'Services',
                      value: s.serviceEligibility.isEmpty
                          ? '-'
                          : s.serviceEligibility.join(', '),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'Approval checks submitted information only, not government ownership records.',
                  style: TextStyle(color: scheme.primary, fontSize: 12),
                ),
                const SizedBox(height: AppSpacing.gutter),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => onReject(s),
                      child: const Text('Reject'),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    ElevatedButton(
                      onPressed: () => onApprove(s),
                      child: const Text('Approve'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: AppTextStyles.labelCaps),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
