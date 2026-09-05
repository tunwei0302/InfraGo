import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/foo/payment_repository.dart';
import 'package:infra_go/heng/driver_models.dart';
import 'package:infra_go/heng/driver_presence_service.dart';
import 'package:infra_go/heng/driver_pickup_navigation_screen.dart';
import 'package:infra_go/heng/driver_repository.dart';
import 'package:infra_go/kueh/osrm_routing_service.dart';
import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/shared/supabase_config.dart';

class _EnrichedOrder {
  const _EnrichedOrder({
    required this.order,
    required this.isGroup,
    required this.pickupEta,
    required this.pickupDistanceKm,
    required this.stopOverview,
    required this.groupSavedKm,
  });

  final Map<String, dynamic> order;
  final bool isGroup;
  final _PickupLeg? pickupEta;
  final double? pickupDistanceKm;
  final List<_GroupStopChip>? stopOverview;
  final double? groupSavedKm;
}

class _PickupLeg {
  const _PickupLeg({required this.distanceMeters, required this.durationSeconds});
  final double distanceMeters;
  final double durationSeconds;
}

class _GroupStopChip {
  const _GroupStopChip({
    required this.kind,
    required this.riderSlot,
    required this.orderIndex,
  });
  final String kind; // 'pickup' | 'dropoff'
  final int riderSlot; // 1 or 2 (anonymous — A then B)
  final int orderIndex; // 0..3, position in the optimised order
}

class AvailableOrdersScreen extends StatefulWidget {
  const AvailableOrdersScreen({super.key});

  @override
  State<AvailableOrdersScreen> createState() => _AvailableOrdersScreenState();
}

class _AvailableOrdersScreenState extends State<AvailableOrdersScreen> {
  final _repository = DriverRepository(supabase);
  final _paymentRepository = PaymentRepository(supabase);
  final _osrm = OsrmRoutingService();
  final _presence = DriverPresenceService(supabase);
  late Future<DriverReadiness> _readiness;
  final Set<String> _accepting = {};
  late final Stream<List<Map<String, dynamic>>> _ordersStream = supabase
      .from('rides')
      .stream(primaryKey: ['id'])
      .order('created_at');

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
        if (groupId == null) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DriverPickupNavigationScreen.solo(
                rideId: order['id'].toString(),
              ),
            ),
          );
        } else {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DriverPickupNavigationScreen.group(
                groupId: groupId,
                firstRideId: order['id'].toString(),
              ),
            ),
          );
        }
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
    'driver_not_online' => 'Go online from Driver Hub before accepting rides.',
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
      stream: _ordersStream,
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
            return FutureBuilder<_EnrichedOrder>(
              future: _enrichOrder(order, vehicle),
              builder: (context, snapshot) {
                final service = order['service_type']?.toString() ?? 'economy_4';
                final passengers = (order['passenger_count'] as num?)?.toInt() ?? 1;
                final isGroup = order['group_id'] != null;
                final knownCompatible =
                    isGroup ||
                    (vehicle.passengerCapacity >= passengers &&
                        (service != 'six_seater' ||
                            vehicle.passengerCapacity >= 6));
                final key = order['group_id']?.toString() ?? order['id'].toString();
                final enriched = snapshot.data;
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
                        if (enriched?.stopOverview != null) ...[
                          const SizedBox(height: AppSpacing.base),
                          _GroupStopOverview(
                            stops: enriched!.stopOverview!,
                            savedKm: enriched.groupSavedKm,
                          ),
                        ],
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
                            if (enriched?.pickupEta != null)
                              _Fact(
                                icon: Icons.directions_car_filled_outlined,
                                text:
                                    'To pickup: ${_distanceString(enriched!.pickupEta!.distanceMeters)} · ${((enriched.pickupEta!.durationSeconds) / 60).ceil()} min',
                              ),
                            if (order['route_distance_meters'] is num)
                              _Fact(
                                icon: Icons.route,
                                text:
                                    'Ride: ${((order['route_distance_meters'] as num) / 1000).toStringAsFixed(1)} km',
                              ),
                            if (order['route_duration_seconds'] is num)
                              _Fact(
                                icon: Icons.schedule,
                                text:
                                    'Ride: ${((order['route_duration_seconds'] as num) / 60).ceil()} min',
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
      },
    );
  }

  Future<_EnrichedOrder> _enrichOrder(
    Map<String, dynamic> order,
    DriverVehicle vehicle,
  ) async {
    final isGroup = order['group_id'] != null;

    _PickupLeg? pickupEta;
    final pickupLat = (order['pickup_latitude'] as num?)?.toDouble();
    final pickupLng = (order['pickup_longitude'] as num?)?.toDouble();
    final driverPos = _presence.lastKnownPosition;
    if (pickupLat != null && pickupLng != null && driverPos != null) {
      try {
        final route = await _osrm.route(
          driverPos,
          LatLng(pickupLat, pickupLng),
        );
        pickupEta = _PickupLeg(
          distanceMeters: route.distanceMeters.toDouble(),
          durationSeconds: route.durationSeconds.toDouble(),
        );
      } catch (_) {
        // Fail silently — we still show the order without pickup ETA.
      }
    }

    List<_GroupStopChip>? stopOverview;
    double? savedKm;
    if (isGroup) {
      try {
        final groupRow = await supabase
            .from('ride_groups')
            .select(
              'optimised_stop_order, vehicle_km_avoided')
            .eq('id', order['group_id'])
            .maybeSingle();
        if (groupRow != null) {
          final stops = (groupRow['optimised_stop_order'] as List?)
              ?.map((e) => (e as num).toInt())
              .toList();
          final avoided = groupRow['vehicle_km_avoided'];
          if (avoided is num) savedKm = avoided.toDouble();
          if (stops != null && stops.isNotEmpty) {
            stopOverview = [
              for (int i = 0; i < stops.length; i++)
              _GroupStopChip(
                kind: stops[i] < 2 ? 'pickup' : 'dropoff',
                riderSlot: stops[i].isEven ? 1 : 2,
                orderIndex: i,
              ),
            ];
          }
        }
      } catch (_) {
        // stop overview is optional
      }
    }

    return _EnrichedOrder(
      order: order,
      isGroup: isGroup,
      pickupEta: pickupEta,
      pickupDistanceKm: pickupEta == null
          ? null
          : pickupEta.distanceMeters / 1000,
      stopOverview: stopOverview,
      groupSavedKm: savedKm,
    );
  }

  String _serviceLabel(String service) => switch (service) {
    'six_seater' => '6-Seater',
    'shared_economy' => 'Shared Economy',
    _ => 'Economy 4',
  };

  static String _distanceString(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }
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

class _GroupStopOverview extends StatelessWidget {
  const _GroupStopOverview({required this.stops, required this.savedKm});
  final List<_GroupStopChip> stops;
  final double? savedKm;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sorted = stops.toList()..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.gutter),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.route, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: AppSpacing.xs),
              Text(
                'Optimised stop order',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (savedKm != null && savedKm! > 0)
                Chip(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: theme.colorScheme.tertiaryContainer,
                  side: BorderSide.none,
                  label: Text(
                    'Saves ${savedKm!.toStringAsFixed(1)} km',
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (int i = 0; i < sorted.length; i++) ...[
                if (i > 0)
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                _StopBadge(stop: sorted[i]),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Stops 1–2 are pickups (P), stops 3–4 are drop-offs (D). '
            'Rider A/B identifiers are anonymous slots.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _StopBadge extends StatelessWidget {
  const _StopBadge({required this.stop});
  final _GroupStopChip stop;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPickup = stop.kind == 'pickup';
    final letter = isPickup ? 'P' : 'D';
    final label =
        '${stop.orderIndex + 1}. $letter${stop.riderSlot}  '
        '(${isPickup ? 'Pickup rider ${stop.riderSlot}' : 'Drop off rider ${stop.riderSlot}'})';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.base,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: isPickup
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: theme.textTheme.labelMedium),
    );
  }
}
