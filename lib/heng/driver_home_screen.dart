import 'dart:async';

import 'package:flutter/material.dart';

import 'package:infra_go/foo/payment_repository.dart';
import 'package:infra_go/heng/available_orders_screen.dart';
import 'package:infra_go/heng/driver_models.dart';
import 'package:infra_go/heng/driver_onboarding_screen.dart';
import 'package:infra_go/heng/driver_presence_service.dart';
import 'package:infra_go/heng/driver_repository.dart';
import 'package:infra_go/kueh/chat_with_driver_screen.dart';
import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/shared/supabase_config.dart';
import 'package:infra_go/tey/user_profile_screen.dart';

class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  int _selectedIndex = 0;

  static const _pages = <Widget>[
    _DriverHubTab(),
    AvailableOrdersScreen(),
    UserProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(index: _selectedIndex, children: _pages),
    bottomNavigationBar: BottomNavigationBar(
      currentIndex: _selectedIndex,
      onTap: (index) => setState(() => _selectedIndex = index),
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.local_taxi), label: 'Hub'),
        BottomNavigationBarItem(icon: Icon(Icons.list_alt), label: 'Orders'),
        BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
      ],
    ),
  );
}

class _DriverHubTab extends StatefulWidget {
  const _DriverHubTab();

  @override
  State<_DriverHubTab> createState() => _DriverHubTabState();
}

class _DriverHubTabState extends State<_DriverHubTab> {
  final _repository = DriverRepository(supabase);
  final _presence = DriverPresenceService(supabase);
  final _paymentRepository = PaymentRepository(supabase);
  late Future<DriverReadiness> _readiness;
  bool _isOnline = false;
  bool _changingOnline = false;
  String? _actionRideId;
  String? _trackedAssignment;

  @override
  void initState() {
    super.initState();
    _readiness = _repository.loadReadiness();
  }

  @override
  void dispose() {
    _presence.dispose();
    if (_isOnline) unawaited(_repository.setOffline());
    super.dispose();
  }

  Future<void> _refreshReadiness() async {
    setState(() => _readiness = _repository.loadReadiness());
    await _readiness;
  }

  Future<void> _openOnboarding() async {
    final submitted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const DriverOnboardingScreen()),
    );
    if (submitted == true) await _refreshReadiness();
  }

  Future<void> _setOnline(bool value, DriverReadiness readiness) async {
    if (_changingOnline) return;
    if (value && !readiness.canGoOnline) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(readiness.guidance)));
      return;
    }
    setState(() => _changingOnline = true);
    try {
      if (value) {
        final capacity = readiness.vehicle!.passengerCapacity;
        await _presence.start(
          vehicleCategories: [
            'economy_4',
            if (capacity >= 2) 'shared_economy',
            if (capacity >= 6) 'six_seater',
          ],
        );
      } else {
        await _presence.stop();
      }
      if (mounted) setState(() => _isOnline = value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _changingOnline = false);
    }
  }

  Future<void> _transition(Map<String, dynamic> ride, String nextStatus) async {
    final rideId = ride['id'].toString();
    String? cancellationReason;
    if (nextStatus == 'cancelled') {
      cancellationReason = await _askCancellationReason();
      if (cancellationReason == null) return;
    }
    setState(() => _actionRideId = rideId);
    try {
      final result = await _repository.transitionRide(
        rideId,
        nextStatus,
        cancellationReason: cancellationReason,
      );
      if (result['success'] != true) {
        throw StateError(result['reason']?.toString() ?? 'transition_failed');
      }
      if (nextStatus == 'completed') await _settleCompletedRides(ride);
      if (nextStatus == 'completed' || nextStatus == 'cancelled') {
        _trackedAssignment = null;
        if (_isOnline) {
          final vehicle = await _repository.loadReadiness();
          await _presence.start(
            vehicleCategories: [
              'economy_4',
              if (vehicle.vehicle!.passengerCapacity >= 2) 'shared_economy',
              if (vehicle.vehicle!.passengerCapacity >= 6) 'six_seater',
            ],
          );
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update ride: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _actionRideId = null);
    }
  }

  Future<void> _settleCompletedRides(Map<String, dynamic> ride) async {
    final groupId = ride['group_id']?.toString();
    final rideIds = groupId == null
        ? [ride['id'].toString()]
        : ((await supabase.from('rides').select('id').eq('group_id', groupId))
                  as List)
              .map((row) => (row as Map)['id'].toString())
              .toList();
    for (final id in rideIds) {
      try {
        final cash = await _paymentRepository.completeCashPayment(id);
        if (cash['success'] == true) continue;
        await _paymentRepository.captureWalletPayment(id);
      } catch (_) {
        // Completion remains durable; payment repository is idempotent and retryable.
      }
    }
  }

  Future<String?> _askCancellationReason() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this ride?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Reason required'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep ride'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().length >= 3) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('Cancel ride'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final driverId = supabase.auth.currentUser?.id;
    return Scaffold(
      appBar: AppBar(title: const Text('InfraGo · Driver Hub')),
      body: driverId == null
          ? const Center(child: Text('Sign in as a driver to continue.'))
          : FutureBuilder<DriverReadiness>(
              future: _readiness,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        'Could not load driver profile: ${snapshot.error}',
                      ),
                    );
                  }
                  return const Center(child: CircularProgressIndicator());
                }
                return _hub(driverId, snapshot.requireData);
              },
            ),
    );
  }

  Widget _hub(String driverId, DriverReadiness readiness) {
    return RefreshIndicator(
      onRefresh: _refreshReadiness,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.marginMobile),
        children: [
          _StatusCard(
            readiness: readiness,
            isOnline: _isOnline,
            changing: _changingOnline,
            onOnlineChanged: (value) => _setOnline(value, readiness),
            onSetup: _openOnboarding,
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Active ride', style: AppTextStyles.labelCaps),
          const SizedBox(height: AppSpacing.xs),
          _activeRide(driverId, readiness.vehicle),
          const SizedBox(height: AppSpacing.md),
          Text('Satisfaction', style: AppTextStyles.labelCaps),
          const SizedBox(height: AppSpacing.xs),
          _RatingSummary(driverId: driverId),
        ],
      ),
    );
  }

  Widget _activeRide(String driverId, DriverVehicle? vehicle) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: supabase
          .from('rides')
          .stream(primaryKey: ['id'])
          .eq('driver_id', driverId)
          .order('created_at'),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text('Could not load active ride: ${snapshot.error}');
        }
        final rides = (snapshot.data ?? [])
            .where(
              (row) =>
                  row['status'] == 'driver_assigned' ||
                  row['status'] == 'en_route',
            )
            .toList();
        if (rides.isEmpty) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.gutter),
              child: Text(
                'No active ride. Go online and open Available Orders.',
              ),
            ),
          );
        }
        final ride = rides.first;
        final status = ride['status'].toString();
        final isBusy = _actionRideId == ride['id'].toString();
        _scheduleAssignedTracking(ride);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (ride['group_id'] != null)
                  const Chip(
                    avatar: Icon(Icons.groups_2, size: 17),
                    label: Text('Shared ride · ordered stops'),
                  ),
                Text(
                  '${ride['pickup']} → ${ride['destination']}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.base),
                Text('Status: ${status.replaceAll('_', ' ')}'),
                if (vehicle != null)
                  Text(
                    '${vehicle.color} ${vehicle.make} ${vehicle.model} · ${vehicle.plateNumber}',
                  ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.base,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChatWithDriverScreen(
                            rideId: ride['id'].toString(),
                            title: 'Message passenger',
                            isDriverView: true,
                            quickReplies: const [
                              'I’m on my way.',
                              'I have arrived at the pickup point.',
                              'Please meet me at the pickup point.',
                            ],
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Contact rider'),
                    ),
                    if (status == 'driver_assigned')
                      FilledButton(
                        onPressed: isBusy
                            ? null
                            : () => _transition(ride, 'en_route'),
                        child: const Text('Start ride'),
                      ),
                    if (status == 'en_route')
                      FilledButton(
                        onPressed: isBusy
                            ? null
                            : () => _transition(ride, 'completed'),
                        child: const Text('Complete ride'),
                      ),
                    TextButton(
                      onPressed: isBusy
                          ? null
                          : () => _transition(ride, 'cancelled'),
                      child: const Text('Cancel with reason'),
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

  void _scheduleAssignedTracking(Map<String, dynamic> ride) {
    final assignment = ride['group_id']?.toString() ?? ride['id'].toString();
    if (_trackedAssignment == assignment) return;
    _trackedAssignment = assignment;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final groupId = ride['group_id']?.toString();
        final rideIds = groupId == null
            ? [ride['id'].toString()]
            : ((await supabase
                          .from('rides')
                          .select('id')
                          .eq('group_id', groupId))
                      as List)
                  .map((row) => (row as Map)['id'].toString())
                  .toList();
        await _presence.startAssigned(rideIds: rideIds);
      } catch (error) {
        _trackedAssignment = null;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Live driver location unavailable: $error')),
          );
        }
      }
    });
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.readiness,
    required this.isOnline,
    required this.changing,
    required this.onOnlineChanged,
    required this.onSetup,
  });

  final DriverReadiness readiness;
  final bool isOnline;
  final bool changing;
  final ValueChanged<bool> onOnlineChanged;
  final VoidCallback onSetup;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: readiness.canGoOnline
                    ? Theme.of(context).colorScheme.tertiaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHigh,
                child: Icon(
                  readiness.canGoOnline
                      ? Icons.verified
                      : Icons.pending_actions,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isOnline ? 'You are online' : 'You are offline',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(readiness.guidance),
                  ],
                ),
              ),
              Switch(
                value: isOnline,
                onChanged: changing ? null : onOnlineChanged,
              ),
            ],
          ),
          if (readiness.vehicle != null) ...[
            const Divider(),
            Text(
              '${readiness.vehicle!.color} ${readiness.vehicle!.make} ${readiness.vehicle!.model}',
            ),
            Text(
              '${readiness.vehicle!.plateNumber} · ${readiness.vehicle!.passengerCapacity} passengers',
            ),
          ],
          if (!readiness.canGoOnline) ...[
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              onPressed: onSetup,
              icon: const Icon(Icons.assignment_ind_outlined),
              label: Text(
                readiness.verificationStatus == ApprovalStatus.rejected ||
                        readiness.vehicleStatus == ApprovalStatus.rejected
                    ? 'Update and resubmit'
                    : 'Complete driver setup',
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _RatingSummary extends StatelessWidget {
  const _RatingSummary({required this.driverId});
  final String driverId;

  Future<Map<String, dynamic>?> _load() async {
    final rows = await supabase
        .from('driver_rating_summary')
        .select()
        .eq('driver_id', driverId)
        .limit(1);
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>?>(
    future: _load(),
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Card(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.gutter),
            child: LinearProgressIndicator(),
          ),
        );
      }
      final data = snapshot.data;
      if (data == null) {
        return const Card(
          child: ListTile(
            leading: Icon(Icons.star_outline),
            title: Text('No ratings yet'),
            subtitle: Text('Completed-trip feedback will appear anonymously.'),
          ),
        );
      }
      final count = (data['rating_count'] as num?)?.toInt() ?? 0;
      final average = (data['average_score'] as num?)?.toDouble() ?? 0;
      return Card(
        child: ListTile(
          leading: const Icon(Icons.star, color: Colors.amber),
          title: Text('${average.toStringAsFixed(1)} / 5'),
          subtitle: Text('$count anonymous rating${count == 1 ? '' : 's'}'),
        ),
      );
    },
  );
}
