import 'package:flutter/material.dart';

import 'package:infra_go/foo/payment_repository.dart';
import 'package:infra_go/heng/driver_models.dart';
import 'package:infra_go/heng/driver_repository.dart';
import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/shared/supabase_config.dart';

class AvailableOrdersScreen extends StatefulWidget {
  const AvailableOrdersScreen({super.key});

  @override
  State<AvailableOrdersScreen> createState() => _AvailableOrdersScreenState();
}

class _AvailableOrdersScreenState extends State<AvailableOrdersScreen> {
  final _repository = DriverRepository(supabase);
  final _paymentRepository = PaymentRepository(supabase);
  late Future<DriverReadiness> _readiness;
  final Set<String> _accepting = {};

  @override
  void initState() {
    super.initState();
    _readiness = _repository.loadReadiness();
  }

  Future<void> _accept(Map<String, dynamic> order) async {
    final groupId = order['group_id']?.toString();
    final key = groupId ?? order['id'].toString();
    if (_accepting.contains(key)) return;
    setState(() => _accepting.add(key));
    try {
      final rideIds = groupId == null
          ? [order['id'].toString()]
          : ((await supabase.from('rides').select('id').eq('group_id', groupId))
                    as List)
                .map((row) => (row as Map)['id'].toString())
                .toList();
      final result = groupId == null
          ? await _repository.acceptRide(order['id'].toString())
          : await _repository.acceptGroup(groupId);
      if (result['success'] != true) {
        throw StateError(_friendlyReason(result['reason']?.toString()));
      }
      for (final rideId in rideIds) {
        try {
          await _paymentRepository.authoriseWalletPayment(rideId);
        } catch (_) {
          // Cash rides have no wallet authorisation to reserve.
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ride accepted. Contact the rider from your hub.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not accept: $error')));
      }
    } finally {
      if (mounted) setState(() => _accepting.remove(key));
    }
  }

  String _friendlyReason(String? reason) => switch (reason) {
    'driver_not_ready' => 'Complete approval before accepting rides.',
    'vehicle_capacity_incompatible' =>
      'Your registered vehicle is too small for this order.',
    'ride_not_available' ||
    'group_not_available' => 'Another driver accepted this order first.',
    _ => reason ?? 'Unknown error',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Available orders')),
      body: FutureBuilder<DriverReadiness>(
        future: _readiness,
        builder: (context, readinessSnapshot) {
          if (readinessSnapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (readinessSnapshot.hasError) {
            return _Message(
              icon: Icons.cloud_off,
              text:
                  'Could not check driver eligibility: ${readinessSnapshot.error}',
            );
          }
          final readiness = readinessSnapshot.requireData;
          if (!readiness.canGoOnline) {
            return _Message(icon: Icons.lock_outline, text: readiness.guidance);
          }
          return _orders(readiness.vehicle!);
        },
      ),
    );
  }

  Widget _orders(DriverVehicle vehicle) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: supabase
          .from('rides')
          .stream(primaryKey: ['id'])
          .order('created_at'),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Message(
            icon: Icons.error_outline,
            text: 'Could not load orders: ${snapshot.error}',
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final seenGroups = <String>{};
        final orders = snapshot.data!.where((row) {
          final status = row['status'];
          if (status != 'requested' && status != 'matched') return false;
          final groupId = row['group_id']?.toString();
          if (groupId != null && !seenGroups.add(groupId)) return false;
          return true;
        }).toList();
        if (orders.isEmpty) {
          return const _Message(
            icon: Icons.route_outlined,
            text: 'No compatible orders nearby yet.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(AppSpacing.marginMobile),
          itemCount: orders.length,
          separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
          itemBuilder: (context, index) {
            final order = orders[index];
            final service = order['service_type']?.toString() ?? 'economy_4';
            final passengers = (order['passenger_count'] as num?)?.toInt() ?? 1;
            final isGroup = order['group_id'] != null;
            final knownCompatible =
                isGroup ||
                (vehicle.passengerCapacity >= passengers &&
                    (service != 'six_seater' ||
                        vehicle.passengerCapacity >= 6));
            final key = order['group_id']?.toString() ?? order['id'].toString();
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.gutter),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isGroup
                              ? Icons.groups_2_outlined
                              : Icons.person_outline,
                        ),
                        const SizedBox(width: AppSpacing.base),
                        Expanded(
                          child: Text(
                            isGroup
                                ? 'Shared ride group'
                                : _serviceLabel(service),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (order['transit_stop_id'] != null)
                          const Chip(label: Text('Transit link')),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      '${order['pickup'] ?? 'Pickup'} → ${order['destination'] ?? 'Destination'}',
                    ),
                    const SizedBox(height: AppSpacing.base),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.xs,
                      children: [
                        _Fact(
                          icon: Icons.people_outline,
                          text: isGroup
                              ? '2 bookings · capacity rechecked'
                              : '$passengers passenger${passengers == 1 ? '' : 's'}',
                        ),
                        if (order['route_distance_meters'] is num)
                          _Fact(
                            icon: Icons.route,
                            text:
                                '${((order['route_distance_meters'] as num) / 1000).toStringAsFixed(1)} km',
                          ),
                        if (order['route_duration_seconds'] is num)
                          _Fact(
                            icon: Icons.schedule,
                            text:
                                '${((order['route_duration_seconds'] as num) / 60).ceil()} min',
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: knownCompatible && !_accepting.contains(key)
                            ? () => _accept(order)
                            : null,
                        child: Text(
                          _accepting.contains(key)
                              ? 'Checking securely…'
                              : knownCompatible
                              ? 'Accept order'
                              : 'Vehicle not eligible',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _serviceLabel(String service) => switch (service) {
    'six_seater' => '6-Seater',
    'shared_economy' => 'Shared Economy',
    _ => 'Economy 4',
  };
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 17),
      const SizedBox(width: AppSpacing.xs),
      Text(text),
    ],
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.marginMobile),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48),
          const SizedBox(height: AppSpacing.sm),
          Text(text, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
