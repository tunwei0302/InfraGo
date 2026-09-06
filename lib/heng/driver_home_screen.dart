import 'dart:async';

import 'package:flutter/material.dart';

import 'package:infra_go/foo/payment_repository.dart';
import 'package:infra_go/heng/available_orders_screen.dart';
import 'package:infra_go/heng/driver_inbox_screen.dart';
import 'package:infra_go/heng/driver_models.dart';
import 'package:infra_go/heng/driver_onboarding_screen.dart';
import 'package:infra_go/heng/driver_pickup_navigation_screen.dart';
import 'package:infra_go/heng/driver_presence_service.dart';
import 'package:infra_go/heng/driver_repository.dart';
import 'package:infra_go/heng/group_navigation_plan.dart';
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
    DriverInboxScreen(),
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
        BottomNavigationBarItem(
          icon: Icon(Icons.chat_bubble_outline),
          activeIcon: Icon(Icons.chat_bubble),
          label: 'Messages',
        ),
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
  Stream<List<Map<String, dynamic>>>? _rideStream;
  String? _rideStreamDriverId;

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
    final groupId = ride['group_id']?.toString();
    final actionKey = groupId ?? rideId;
    String? cancellationReason;
    if (nextStatus == 'cancelled') {
      cancellationReason = await _askCancellationReason();
      if (cancellationReason == null) return;
    }
    setState(() => _actionRideId = actionKey);
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
      await _settleRidePayment(id);
    }
  }

  Future<void> _settleRidePayment(String rideId) async {
    try {
      final cash = await _paymentRepository.completeCashPayment(rideId);
      if (cash['success'] == true) return;
      await _paymentRepository.captureWalletPayment(rideId);
    } catch (_) {
      // Completion remains durable; payment repository is idempotent and retryable.
    }
  }

  Future<void> _markSharedStopDone(String groupId) async {
    if (_actionRideId != null) return;
    setState(() => _actionRideId = groupId);
    try {
      final result = await _repository.advanceGroupStop(groupId);
      if (result['success'] != true) {
        throw StateError(result['reason']?.toString() ?? 'advance_failed');
      }

      final completed = result['completed'] == true;
      final confirmedIndex = (result['confirmed_stop_idx'] as num?)?.toInt();
      final nextIndex = (result['current_stop_idx'] as num?)?.toInt();
      final confirmedRideId = result['confirmed_ride_id']?.toString();
      final confirmedStopKind = result['confirmed_stop_kind']?.toString();
      if (confirmedStopKind == 'dropoff' && confirmedRideId != null) {
        await _settleRidePayment(confirmedRideId);
      }
      if (completed) {
        _trackedAssignment = null;
        if (_isOnline) {
          final readiness = await _repository.loadReadiness();
          final capacity = readiness.vehicle!.passengerCapacity;
          await _presence.start(
            vehicleCategories: [
              'economy_4',
              if (capacity >= 2) 'shared_economy',
              if (capacity >= 6) 'six_seater',
            ],
          );
        }
      }

      if (!mounted) return;
      final message = completed
          ? 'Final drop-off marked done. Shared ride completed.'
          : 'Stop ${(confirmedIndex ?? 0) + 1} marked done. '
                'Continue to stop ${(nextIndex ?? 0) + 1}.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not mark this stop done: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _actionRideId = null);
    }
  }

  Future<String?> _askCancellationReason() {
    return showDialog<String>(
      context: context,
      builder: (context) => const _CancellationReasonDialog(),
    );
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

  Stream<List<Map<String, dynamic>>> _ridesStreamFor(String driverId) {
    if (_rideStream == null || _rideStreamDriverId != driverId) {
      _rideStreamDriverId = driverId;
      _rideStream = supabase
          .from('rides')
          .stream(primaryKey: ['id'])
          .eq('driver_id', driverId)
          .order('created_at');
    }
    return _rideStream!;
  }

  Widget _activeRide(String driverId, DriverVehicle? vehicle) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _ridesStreamFor(driverId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text('Could not load active ride: ${snapshot.error}');
        }
        final allDriverRides = snapshot.data ?? [];
        final activeRides = allDriverRides
            .where(
              (row) =>
                  row['status'] == 'driver_assigned' ||
                  row['status'] == 'en_route',
            )
            .toList();
        if (activeRides.isEmpty) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.gutter),
              child: Text(
                'No active ride. Go online and open Available Orders.',
              ),
            ),
          );
        }
        final lead = activeRides.first;
        final groupId = lead['group_id']?.toString();
        final isShared = groupId != null;
        final conversationRides = isShared
            ? allDriverRides
                  .where(
                    (row) =>
                        row['group_id']?.toString() == groupId &&
                        row['status'] != 'cancelled',
                  )
                  .toList()
            : activeRides;
        final status = lead['status'].toString();
        final actionKey = groupId ?? lead['id'].toString();
        final isBusy = _actionRideId == actionKey;
        _scheduleAssignedTracking(lead);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.gutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isShared)
                  const Chip(
                    avatar: Icon(Icons.groups_2, size: 17),
                    label: Text('Shared ride · ordered stops'),
                  ),
                Text(
                  isShared
                      ? '${conversationRides.length} rider chats — one private inbox per ride'
                      : '${lead['pickup']} → ${lead['destination']}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.base),
                _CancellationCountdown(ride: lead),
                Text('Status: ${status.replaceAll('_', ' ')}'),
                if (vehicle != null)
                  Text(
                    '${vehicle.color} ${vehicle.make} ${vehicle.model} · ${vehicle.plateNumber}',
                  ),
                if (isShared) ...[
                  const SizedBox(height: AppSpacing.base),
                  _GroupTripStepper(
                    groupId: groupId,
                    actionBusy: isBusy,
                    onMarkDone: () => _markSharedStopDone(groupId),
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.base,
                  children: [
                    ...conversationRides.asMap().entries.map((e) {
                      final index = e.key;
                      final r = e.value;
                      return OutlinedButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatWithDriverScreen(
                              rideId: r['id'].toString(),
                              title: isShared
                                  ? 'Rider chat ${index + 1} (separate)'
                                  : 'Message passenger',
                              isDriverView: true,
                              quickReplies: const [
                                'I’m on my way.',
                                'I have arrived at the pickup point.',
                                'Please meet me at the pickup point.',
                                'Traffic delay — I may be about 5 minutes late.',
                                'Please confirm the pickup landmark shown in your app.',
                              ],
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: Text(
                          isShared ? 'Rider ${index + 1}' : 'Contact rider',
                        ),
                      );
                    }),
                    FilledButton.icon(
                      onPressed: isBusy
                          ? null
                          : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: isShared
                                    ? (_) => DriverPickupNavigationScreen.group(
                                        groupId: groupId,
                                        firstRideId: lead['id'].toString(),
                                      )
                                    : (_) => DriverPickupNavigationScreen.solo(
                                        rideId: lead['id'].toString(),
                                      ),
                              ),
                            ),
                      icon: const Icon(Icons.navigation_outlined),
                      label: const Text('Navigate'),
                    ),
                    if (!isShared && status == 'driver_assigned')
                      FilledButton(
                        onPressed: isBusy
                            ? null
                            : () => _transition(lead, 'en_route'),
                        child: const Text('Start ride'),
                      ),
                    if (!isShared && status == 'en_route')
                      FilledButton(
                        onPressed: isBusy
                            ? null
                            : () => _transition(lead, 'completed'),
                        child: const Text('Complete ride'),
                      ),
                    TextButton(
                      onPressed: isBusy
                          ? null
                          : () => _transition(lead, 'cancelled'),
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

class _CancellationReasonDialog extends StatefulWidget {
  const _CancellationReasonDialog();

  @override
  State<_CancellationReasonDialog> createState() =>
      _CancellationReasonDialogState();
}

class _CancellationReasonDialogState extends State<_CancellationReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cancel this ride?'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Reason required'),
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            Navigator.pop(context);
          },
          child: const Text('Keep ride'),
        ),
        FilledButton(
          onPressed: () {
            if (_controller.text.trim().length >= 3) {
              FocusScope.of(context).unfocus();
              Navigator.pop(context, _controller.text.trim());
            }
          },
          child: const Text('Cancel ride'),
        ),
      ],
    );
  }
}

class _CancellationCountdown extends StatefulWidget {
  const _CancellationCountdown({required this.ride});
  final Map<String, dynamic> ride;

  @override
  State<_CancellationCountdown> createState() => _CancellationCountdownState();
}

class _CancellationCountdownState extends State<_CancellationCountdown> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final acceptedStr = widget.ride['accepted_at']?.toString();
    final freeUntilStr = widget.ride['free_cancel_until']?.toString();
    final theme = Theme.of(context);
    if (acceptedStr == null || freeUntilStr == null) {
      return const SizedBox.shrink();
    }
    final acceptedAt = DateTime.tryParse(acceptedStr);
    final freeUntil = DateTime.tryParse(freeUntilStr);
    if (acceptedAt == null || freeUntil == null) {
      return const SizedBox.shrink();
    }
    final now = DateTime.now();
    if (now.isAfter(freeUntil)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: theme.colorScheme.error),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                'Free cancel window passed — rider cancellation now incurs a fee.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final remaining = freeUntil.difference(now);
    final mm = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    final percent = 1 - remaining.inSeconds / 180;
    final isUrgent = remaining.inSeconds < 60;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.gutter,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: isUrgent
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.schedule,
                size: 18,
                color: isUrgent
                    ? theme.colorScheme.onErrorContainer
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                'Free cancel: $mm:$ss left',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isUrgent
                      ? theme.colorScheme.onErrorContainer
                      : theme.colorScheme.primary,
                ),
              ),
              const Spacer(),
              Text('Grace period: 3 min', style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: percent.clamp(0, 1),
              backgroundColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupTripStepper extends StatelessWidget {
  const _GroupTripStepper({
    required this.groupId,
    required this.actionBusy,
    required this.onMarkDone,
  });

  final String? groupId;
  final bool actionBusy;
  final VoidCallback onMarkDone;

  Future<({List<int> stops, int? current})> _load() async {
    final gid = groupId;
    if (gid == null) return (stops: const <int>[], current: null as int?);
    final row = await supabase
        .from('ride_groups')
        .select('optimised_stop_order, current_stop_idx')
        .eq('id', gid)
        .maybeSingle();
    final stops =
        (row?['optimised_stop_order'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        const <int>[];
    final current = row?['current_stop_idx'] is num
        ? (row!['current_stop_idx'] as num).toInt()
        : null;
    return (stops: stops, current: current);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder(
      future: _load(),
      builder: (context, snapshot) {
        final data = snapshot.data;
        final stops = data?.stops ?? const <int>[];
        final current = data?.current;
        if (stops.isEmpty) {
          return const Text('Stop order loading…');
        }
        final action = currentGroupStopAction(
          stopOrder: stops,
          storedIndex: current,
        );
        final displayStops = [
          for (int i = 0; i < stops.length; i++)
            (
              display: '${stops[i] < 2 ? 'P' : 'D'}${(stops[i] % 2) + 1}',
              kind: stops[i] < 2 ? 'Pickup' : 'Drop off',
              slot: (stops[i] % 2) + 1,
              index: i,
            ),
        ];
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.gutter),
          decoration: BoxDecoration(
            color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                current == null
                    ? 'Preparing the first pickup…'
                    : 'Stop ${current + 1} of ${stops.length} is active. Mark it done after the pickup or drop-off happens.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (int i = 0; i < displayStops.length; i++) ...[
                    Expanded(
                      child: Column(
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: (current != null && i < current)
                                ? theme.colorScheme.primary
                                : (current == i
                                      ? theme.colorScheme.tertiary
                                      : theme
                                            .colorScheme
                                            .surfaceContainerHighest),
                            child: Icon(
                              current != null && i < current
                                  ? Icons.check
                                  : (current == i
                                        ? Icons.navigation_outlined
                                        : Icons.circle_outlined),
                              size: 18,
                              color: (current != null && i <= current)
                                  ? (i < current
                                        ? theme.colorScheme.onPrimary
                                        : theme.colorScheme.onTertiary)
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (current == i)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                'NEXT',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.tertiary,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            displayStops[i].display,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            '${displayStops[i].kind} ${displayStops[i].slot}',
                            style: theme.textTheme.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                    if (i < displayStops.length - 1)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 17),
                          child: Divider(
                            thickness: 2,
                            color: (current != null && i < current)
                                ? theme.colorScheme.primary
                                : theme.colorScheme.surfaceContainerHighest,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.base),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: actionBusy ? null : onMarkDone,
                  icon: actionBusy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          action.isPickup
                              ? Icons.person_add_alt_1
                              : Icons.where_to_vote_outlined,
                        ),
                  label: Text(
                    actionBusy
                        ? 'Updating ${action.code}…'
                        : action.buttonLabel,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
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
