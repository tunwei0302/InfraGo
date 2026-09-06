import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/foo/payment_repository.dart';
import 'package:infra_go/heng/driver_repository.dart';
import 'package:infra_go/heng/group_navigation_plan.dart';
import 'package:infra_go/kueh/chat_with_driver_screen.dart';
import 'package:infra_go/kueh/osrm_routing_service.dart';
import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/shared/supabase_config.dart';

class DriverPickupNavigationScreen extends StatefulWidget {
  const DriverPickupNavigationScreen.solo({super.key, required this.rideId})
    : groupId = null,
      firstRideId = rideId ?? '';

  const DriverPickupNavigationScreen.group({
    super.key,
    required this.groupId,
    required this.firstRideId,
  }) : rideId = null;

  final String? rideId;
  final String? groupId;
  final String firstRideId;

  @override
  State<DriverPickupNavigationScreen> createState() =>
      _DriverPickupNavigationScreenState();
}

enum _NavTargetKind { soloPickup, soloDestination, groupStop }

class _NavTarget {
  const _NavTarget({
    required this.point,
    required this.label,
    required this.kind,
    required this.shortLabel,
    this.riderSlot,
    this.rideId,
  });

  final LatLng point;
  final String label;
  final String shortLabel;
  final _NavTargetKind kind;
  final int? riderSlot;
  final String? rideId;
}

class _DriverPickupNavigationScreenState
    extends State<DriverPickupNavigationScreen> {
  final MapController _mapController = MapController();
  final OsrmRoutingService _osrm = OsrmRoutingService();
  final DriverRepository _repository = DriverRepository(supabase);
  final PaymentRepository _paymentRepository = PaymentRepository(supabase);

  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _ridesSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _groupsSubscription;
  DateTime _lastRecalcAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _lastFallbackWasStraight = false;

  List<Map<String, dynamic>> _groupRides = const [];
  Map<String, int> _groupRideSlots = const {};
  List<int> _groupStopOrder = const [];
  int? _currentStopIdx;
  bool _advancingStop = false;

  Position? _driverPosition;
  double? _lastHeading;
  LatLng? _targetPoint;
  List<LatLng> _polyline = const [];
  RouteResult? _routeResult;
  String? _routeError;
  _NavTarget? _target;
  bool _following = true;
  bool _disposed = false;
  bool _mapReady = false;

  String? _statusError;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _disposed = true;
    _positionSubscription?.cancel();
    _ridesSubscription?.cancel();
    _groupsSubscription?.cancel();
    _osrm.close();
    super.dispose();
  }

  bool get _isGroup => widget.groupId != null;

  Future<void> _bootstrap() async {
    try {
      await _ensurePermission();
      final initial = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (_disposed) return;
      _setDriverPosition(initial);

      if (_isGroup) {
        await _subscribeGroupStreams();
      } else {
        await _subscribeSoloStream();
      }

      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 5,
            ),
          ).listen((pos) {
            if (_disposed) return;
            _setDriverPosition(pos);
            unawaited(_maybeRecalculateRoute());
          }, onError: (_) {});
    } catch (error) {
      if (!mounted) return;
      final message = _isGroup
          ? 'Could not load the shared stop plan. Please retry.'
          : error.toString();
      setState(() => _statusError = message);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const FormatException(
        'Turn on location services to start turn-by-turn navigation.',
      );
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const FormatException(
        'Location permission is required for navigation.',
      );
    }
  }

  void _setDriverPosition(Position pos) {
    _driverPosition = pos;
    if (pos.heading.isFinite && pos.speed > 0.5) {
      _lastHeading = pos.heading;
    }
    if (!_disposed && mounted) {
      setState(() {});
      if (_following && _mapReady) {
        _mapController.move(LatLng(pos.latitude, pos.longitude), 16);
      }
    }
  }

  Future<void> _subscribeSoloStream() async {
    final rideId = widget.rideId!;
    final firstSnapshot = await supabase
        .from('rides')
        .select()
        .eq('id', rideId)
        .maybeSingle();
    if (firstSnapshot != null) {
      await _applySoloRide(firstSnapshot);
    }
    _ridesSubscription = supabase
        .from('rides')
        .stream(primaryKey: ['id'])
        .eq('id', rideId)
        .listen((rows) {
          if (rows.isEmpty || _disposed) return;
          unawaited(_applySoloRide(Map<String, dynamic>.from(rows.first)));
        });
  }

  Future<void> _applySoloRide(Map<String, dynamic> ride) async {
    final pickupLat = (ride['pickup_latitude'] as num?)?.toDouble();
    final pickupLng = (ride['pickup_longitude'] as num?)?.toDouble();
    final destLat = (ride['destination_latitude'] as num?)?.toDouble();
    final destLng = (ride['destination_longitude'] as num?)?.toDouble();
    final pickupText = ride['pickup']?.toString() ?? 'Pickup point';
    final destText = ride['destination']?.toString() ?? 'Destination';
    final status = ride['status']?.toString();

    _NavTarget next;
    if (status == 'en_route' && destLat != null && destLng != null) {
      next = _NavTarget(
        point: LatLng(destLat, destLng),
        label: 'Navigate to destination · $destText',
        shortLabel: destText,
        kind: _NavTargetKind.soloDestination,
        rideId: ride['id'].toString(),
      );
    } else if (pickupLat != null && pickupLng != null) {
      next = _NavTarget(
        point: LatLng(pickupLat, pickupLng),
        label: 'Navigate to pickup · $pickupText',
        shortLabel: pickupText,
        kind: _NavTargetKind.soloPickup,
        rideId: ride['id'].toString(),
      );
    } else {
      return;
    }
    await _applyTarget(next, announce: false);
  }

  Future<void> _subscribeGroupStreams() async {
    final groupId = widget.groupId!;
    final groupRow = await _loadGroupRow(groupId);
    if (groupRow == null) {
      throw const FormatException('Assigned shared group was not found.');
    }
    _groupStopOrder = ((groupRow['optimised_stop_order'] as List?) ?? const [])
        .map((e) => (e as num).toInt())
        .toList(growable: false);
    _currentStopIdx = groupRow['current_stop_idx'] is num
        ? (groupRow['current_stop_idx'] as num).toInt()
        : null;

    final memberRows = await supabase
        .from('ride_group_members')
        .select('ride_id, stop_index_pickup, stop_index_destination')
        .eq('group_id', groupId);
    _groupRideSlots = buildGroupRideSlots(
      stopOrder: _groupStopOrder,
      members: memberRows.map(
        (row) => GroupMemberStops(
          rideId: row['ride_id'].toString(),
          pickupOrderIndex: (row['stop_index_pickup'] as num).toInt(),
          destinationOrderIndex: (row['stop_index_destination'] as num).toInt(),
        ),
      ),
    );

    final ridesRows = await supabase
        .from('rides')
        .select()
        .eq('group_id', groupId);
    _groupRides = _orderGroupRides(ridesRows);
    await _applyGroupTarget(announce: false);

    _ridesSubscription = supabase
        .from('rides')
        .stream(primaryKey: ['id'])
        .eq('group_id', groupId)
        .listen((rows) {
          if (_disposed) return;
          _groupRides = _orderGroupRides(rows);
          unawaited(_applyGroupTarget(announce: true));
        });

    _groupsSubscription = supabase
        .from('ride_groups')
        .stream(primaryKey: ['id'])
        .eq('id', groupId)
        .listen((rows) {
          if (rows.isEmpty || _disposed) return;
          final row = Map<String, dynamic>.from(rows.first);
          _groupStopOrder = ((row['optimised_stop_order'] as List?) ?? const [])
              .map((e) => (e as num).toInt())
              .toList(growable: false);
          final newIdx = row['current_stop_idx'] is num
              ? (row['current_stop_idx'] as num).toInt()
              : null;
          if (newIdx != _currentStopIdx) {
            _currentStopIdx = newIdx;
            unawaited(_applyGroupTarget(announce: true));
          } else {
            _currentStopIdx = newIdx;
            unawaited(_applyGroupTarget(announce: false));
          }
        });
  }

  Future<Map<String, dynamic>?> _loadGroupRow(String groupId) async {
    try {
      return await supabase
          .from('ride_groups')
          .select('optimised_stop_order, current_stop_idx, status')
          .eq('id', groupId)
          .maybeSingle();
    } catch (error) {
      // Keep the screen usable while an older database is being migrated.
      if (!error.toString().contains('current_stop_idx')) rethrow;
      return supabase
          .from('ride_groups')
          .select('optimised_stop_order, status')
          .eq('id', groupId)
          .maybeSingle();
    }
  }

  List<Map<String, dynamic>> _orderGroupRides(
    Iterable<Map<String, dynamic>> rows,
  ) {
    final ordered = List<Map<String, dynamic>?>.filled(2, null);
    for (final source in rows) {
      final row = Map<String, dynamic>.from(source);
      final slot = _groupRideSlots[row['id'].toString()];
      if (slot != null && slot >= 0 && slot < ordered.length) {
        ordered[slot] = row;
      }
    }
    final result = ordered.whereType<Map<String, dynamic>>().toList();
    if (result.length != 2) {
      throw const FormatException('Both shared rides must be readable.');
    }
    return result;
  }

  Future<void> _applyGroupTarget({required bool announce}) async {
    if (_groupRides.isEmpty || _groupStopOrder.isEmpty) return;
    final stopIdx = activeGroupStopIndex(
      _currentStopIdx,
      _groupStopOrder.length,
    );
    if (stopIdx < 0 || stopIdx >= _groupStopOrder.length) return;
    final stopCode = _groupStopOrder[stopIdx];
    final riderIndex = stopCode.isEven ? 0 : 1;
    final isPickup = stopCode < 2;
    if (riderIndex >= _groupRides.length) return;
    final ride = _groupRides[riderIndex];

    final lat = isPickup
        ? (ride['pickup_latitude'] as num?)?.toDouble()
        : (ride['destination_latitude'] as num?)?.toDouble();
    final lng = isPickup
        ? (ride['pickup_longitude'] as num?)?.toDouble()
        : (ride['destination_longitude'] as num?)?.toDouble();
    if (lat == null || lng == null) return;

    final text = isPickup
        ? (ride['pickup']?.toString() ?? 'Pickup point')
        : (ride['destination']?.toString() ?? 'Destination');
    final pd = isPickup ? 'P' : 'D';
    final slot = riderIndex + 1;
    final target = _NavTarget(
      point: LatLng(lat, lng),
      label:
          'Stop ${stopIdx + 1} · ${isPickup ? 'Pickup' : 'Drop off'} Rider $slot · $text',
      shortLabel: '$pd$slot · $text',
      kind: _NavTargetKind.groupStop,
      riderSlot: slot,
      rideId: ride['id'].toString(),
    );
    await _applyTarget(target, announce: announce);
  }

  Future<void> _applyTarget(_NavTarget next, {required bool announce}) async {
    final changed =
        _target == null ||
        _target!.point.latitude.toStringAsFixed(5) !=
            next.point.latitude.toStringAsFixed(5) ||
        _target!.point.longitude.toStringAsFixed(5) !=
            next.point.longitude.toStringAsFixed(5) ||
        _target!.kind != next.kind;
    _target = next;
    _targetPoint = next.point;
    if (!mounted || _disposed) return;
    setState(() {});
    if (changed) {
      await _recalculateRoute(force: true);
      if (_mapReady) {
        unawaited(_fitRoute());
      }
      if (announce && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(next.label)));
      }
    }
  }

  Future<void> _recalculateRoute({required bool force}) async {
    final pos = _driverPosition;
    final target = _targetPoint;
    if (pos == null || target == null) return;
    if (!force && !_shouldRecalculate(LatLng(pos.latitude, pos.longitude))) {
      return;
    }
    _lastRecalcAt = DateTime.now();
    try {
      final route = await _osrm.route(
        LatLng(pos.latitude, pos.longitude),
        target,
        useCache: !force,
      );
      if (_disposed) return;
      _routeResult = route;
      _polyline = route.points;
      _routeError = null;
      _lastFallbackWasStraight = false;
    } catch (error) {
      if (_disposed) return;
      _polyline = [LatLng(pos.latitude, pos.longitude), target];
      _routeResult = RouteResult(
        points: _polyline,
        distanceMeters: haversineMeters(
          LatLng(pos.latitude, pos.longitude),
          target,
        ),
        durationSeconds:
            haversineMeters(LatLng(pos.latitude, pos.longitude), target) /
            1000 /
            25 *
            3600,
      );
      _routeError = error.toString();
      _lastFallbackWasStraight = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Routing unavailable, using straight line: $error'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _maybeRecalculateRoute() async {
    final pos = _driverPosition;
    if (pos == null) return;
    if (DateTime.now().difference(_lastRecalcAt).inSeconds < 15) return;
    await _recalculateRoute(force: false);
  }

  bool _shouldRecalculate(LatLng driverPos) {
    if (_polyline.length < 2) return true;
    if (_lastFallbackWasStraight) return true;
    double best = double.infinity;
    for (int i = 0; i < _polyline.length - 1; i++) {
      final d = _pointToSegmentMeters(
        driverPos,
        _polyline[i],
        _polyline[i + 1],
      );
      if (d < best) best = d;
    }
    return best > 50;
  }

  double _pointToSegmentMeters(LatLng p, LatLng a, LatLng b) {
    final dxA = b.longitude - a.longitude;
    final dyA = b.latitude - a.latitude;
    final len2 = dxA * dxA + dyA * dyA;
    if (len2 == 0) return haversineMeters(p, a);
    final t =
        ((p.longitude - a.longitude) * dxA + (p.latitude - a.latitude) * dyA) /
        len2;
    final tc = t.clamp(0.0, 1.0);
    final proj = LatLng(a.latitude + tc * dyA, a.longitude + tc * dxA);
    return haversineMeters(p, proj);
  }

  Future<void> _fitRoute() async {
    final pos = _driverPosition;
    final target = _targetPoint;
    if (pos == null || target == null) return;
    final points = <LatLng>[
      LatLng(pos.latitude, pos.longitude),
      target,
      ...?_routeResult?.points,
    ];
    try {
      _mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: points,
          padding: const EdgeInsets.all(80),
        ),
      );
    } catch (_) {}
  }

  _Maneuver _computeManeuverHint() {
    final pos = _driverPosition;
    final route = _routeResult;
    if (pos == null || route == null || route.points.length < 2) {
      return const _Maneuver(
        icon: Icons.navigation_outlined,
        text: 'Calculating…',
      );
    }
    final driverPos = LatLng(pos.latitude, pos.longitude);
    final (projIdx, accumDistFromStart, _) = _projectOntoPolyline(
      driverPos,
      route.points,
    );

    final waypointTargetMeters = 120.0;
    int i = projIdx;
    double walked = 0;
    double remainingAlong = 0;
    LatLng? waypoint;
    LatLng prev = route.points[i];
    while (i < route.points.length - 1) {
      final next = route.points[i + 1];
      final segLen = haversineMeters(prev, next);
      if (i == projIdx) {
        final afterProjOnSeg = segLen - accumDistFromStart;
        if (walked + afterProjOnSeg >= waypointTargetMeters) {
          final ratio =
              (waypointTargetMeters - walked) /
              (afterProjOnSeg > 0 ? afterProjOnSeg : 1);
          waypoint = LatLng(
            prev.latitude + (next.latitude - prev.latitude) * ratio.clamp(0, 1),
            prev.longitude +
                (next.longitude - prev.longitude) * ratio.clamp(0, 1),
          );
          remainingAlong = waypointTargetMeters;
          break;
        } else {
          walked += afterProjOnSeg;
        }
      } else {
        if (walked + segLen >= waypointTargetMeters) {
          final ratio =
              (waypointTargetMeters - walked) / (segLen > 0 ? segLen : 1);
          waypoint = LatLng(
            prev.latitude + (next.latitude - prev.latitude) * ratio.clamp(0, 1),
            prev.longitude +
                (next.longitude - prev.longitude) * ratio.clamp(0, 1),
          );
          remainingAlong = waypointTargetMeters;
          break;
        }
        walked += segLen;
      }
      prev = next;
      i++;
    }
    waypoint ??= route.points.last;
    remainingAlong = remainingAlong > 0
        ? remainingAlong
        : (route.distanceMeters -
              _distanceAlongFromStart(
                route.points,
                projIdx,
                accumDistFromStart,
              ));

    final heading =
        _lastHeading ??
        bearingBetween(
          driverPos,
          route.points[(projIdx + 1).clamp(0, route.points.length - 1)],
        );
    final nextBearing = bearingBetween(driverPos, waypoint);
    final diff = ((nextBearing - heading) + 360) % 360;
    final (icon, text) = _classifyDirection(diff);
    return _Maneuver(icon: icon, text: text, distanceMeters: remainingAlong);
  }

  static (IconData, String) _classifyDirection(double diff) {
    if (diff <= 20 || diff >= 340) {
      return (Icons.straight, 'Continue straight');
    }
    if (diff < 60) return (Icons.turn_slight_right_outlined, 'Slight right');
    if (diff < 120) return (Icons.turn_right, 'Turn right');
    if (diff < 160) return (Icons.turn_sharp_right, 'Sharp right');
    if (diff <= 200) return (Icons.u_turn_left, 'Make a U-turn');
    if (diff < 240) return (Icons.turn_sharp_left, 'Sharp left');
    if (diff < 300) return (Icons.turn_left, 'Turn left');
    return (Icons.turn_slight_left_outlined, 'Slight left');
  }

  (int index, double distFromPrevSegmentStartMeters, LatLng projectedPoint)
  _projectOntoPolyline(LatLng p, List<LatLng> polyline) {
    int bestI = 0;
    double bestDist = double.infinity;
    double bestT = 0;
    for (int i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i];
      final b = polyline[i + 1];
      final dxB = b.longitude - a.longitude;
      final dyB = b.latitude - a.latitude;
      final len2 = dxB * dxB + dyB * dyB;
      final double t;
      if (len2 == 0) {
        t = 0;
      } else {
        t =
            (((p.longitude - a.longitude) * dxB +
                        (p.latitude - a.latitude) * dyB) /
                    len2)
                .clamp(0.0, 1.0);
      }
      final proj = LatLng(a.latitude + t * dyB, a.longitude + t * dxB);
      final d = haversineMeters(p, proj);
      if (d < bestDist) {
        bestDist = d;
        bestI = i;
        bestT = t;
      }
    }
    final a = polyline[bestI];
    final b = polyline[(bestI + 1).clamp(0, polyline.length - 1)];
    final proj = LatLng(
      a.latitude + bestT * (b.latitude - a.latitude),
      a.longitude + bestT * (b.longitude - a.longitude),
    );
    final segLen = haversineMeters(a, b);
    return (bestI, segLen * bestT, proj);
  }

  double _distanceAlongFromStart(List<LatLng> poly, int idx, double into) {
    double total = 0;
    for (int i = 0; i < idx; i++) {
      total += haversineMeters(poly[i], poly[i + 1]);
    }
    return total + into;
  }

  double _remainingDistanceMeters() {
    final pos = _driverPosition;
    final target = _targetPoint;
    final route = _routeResult;
    if (target == null) return 0;
    if (pos == null) {
      return route?.distanceMeters ?? haversineMeters(LatLng(0, 0), target);
    }
    final driverPos = LatLng(pos.latitude, pos.longitude);
    if (route == null || route.points.length < 2) {
      return haversineMeters(driverPos, target);
    }
    final (projIdx, accum, _) = _projectOntoPolyline(driverPos, route.points);
    final fromProj =
        route.distanceMeters -
        _distanceAlongFromStart(route.points, projIdx, accum);
    return fromProj < 0 ? 0 : fromProj;
  }

  String _etaLabel() {
    final remaining = _remainingDistanceMeters();
    final route = _routeResult;
    if (route == null) return '…';
    final totalDist = route.distanceMeters <= 0 ? 1 : route.distanceMeters;
    final ratio = remaining.clamp(0, totalDist) / totalDist;
    final seconds = (route.durationSeconds * ratio).round();
    final minutes = (seconds / 60).floor();
    if (minutes < 1) return '< 1 min';
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  bool _isArrived() {
    final pos = _driverPosition;
    final target = _targetPoint;
    if (pos == null || target == null) return false;
    return haversineMeters(LatLng(pos.latitude, pos.longitude), target) <= 50;
  }

  Future<void> _arrivedAction() async {
    try {
      HapticFeedback.lightImpact();
    } catch (_) {}
    final rideId = _target?.rideId;
    if (rideId == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatWithDriverScreen(
          rideId: rideId,
          title: 'Quick update to rider',
          isDriverView: true,
          quickReplies: const [
            'I have arrived at the pickup point.',
            'I’m on my way.',
            'Please meet me at the pickup point.',
          ],
        ),
      ),
    );
  }

  Future<void> _confirmCurrentGroupStop() async {
    final groupId = widget.groupId;
    if (groupId == null || _advancingStop) return;
    setState(() => _advancingStop = true);
    try {
      final result = await _repository.advanceGroupStop(groupId);
      if (result['success'] != true) {
        throw StateError(result['reason']?.toString() ?? 'advance_failed');
      }
      final confirmedRideId = result['confirmed_ride_id']?.toString();
      if (result['confirmed_stop_kind'] == 'dropoff' &&
          confirmedRideId != null) {
        await _settleRidePayment(confirmedRideId);
      }
      final completed = result['completed'] == true;
      if (completed) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Shared ride completed.')));
        Navigator.pop(context, true);
        return;
      }
      final nextIndex = result['current_stop_idx'];
      if (nextIndex is num) _currentStopIdx = nextIndex.toInt();
      await _applyGroupTarget(announce: true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not confirm this stop: $error')),
      );
    } finally {
      if (mounted) setState(() => _advancingStop = false);
    }
  }

  Future<void> _settleRidePayment(String rideId) async {
    try {
      final cash = await _paymentRepository.completeCashPayment(rideId);
      if (cash['success'] == true) return;
      await _paymentRepository.captureWalletPayment(rideId);
    } catch (_) {
      // Completion is durable; the idempotent payment call can be retried.
    }
  }

  String get _confirmStopLabel {
    if (_groupStopOrder.isEmpty) return 'Confirm stop';
    final index = activeGroupStopIndex(_currentStopIdx, _groupStopOrder.length);
    final isPickup = _groupStopOrder[index] < 2;
    final isLast = nextGroupStopIndex(index, _groupStopOrder.length) == null;
    if (isLast) return 'Complete final drop-off';
    return isPickup ? 'Confirm pickup & next stop' : 'Confirm drop-off & next';
  }

  Future<void> _openChatForCurrentRide() async {
    final rideId = _target?.rideId;
    if (!mounted) return;
    if (_isGroup) {
      final selected = await showDialog<int>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Choose rider chat'),
          children: [
            for (int i = 0; i < _groupRides.length; i++)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    'Rider ${i + 1} · ${_groupRides[i]['pickup'] ?? 'Pickup'}',
                  ),
                ),
              ),
          ],
        ),
      );
      if (!mounted || selected == null || selected >= _groupRides.length) {
        return;
      }
      final openRideId = _groupRides[selected]['id'].toString();
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatWithDriverScreen(
            rideId: openRideId,
            title: 'Rider ${selected + 1}',
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
      );
      return;
    }
    if (rideId == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatWithDriverScreen(
          rideId: rideId,
          title: 'Message passenger',
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final arrived = _isArrived();
    final maneuver = _computeManeuverHint();
    final eta = _etaLabel();
    final remainingMeters = _remainingDistanceMeters();
    final markers = <Marker>[];
    final pos = _driverPosition;
    final target = _targetPoint;
    if (pos != null) {
      markers.add(
        Marker(
          point: LatLng(pos.latitude, pos.longitude),
          width: 40,
          height: 40,
          alignment: Alignment.center,
          child: Semantics(
            label: 'Your vehicle position',
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Transform.rotate(
                angle: (_lastHeading ?? 0) * 3.14159265 / 180,
                child: const Icon(
                  Icons.navigation,
                  color: Colors.white,
                  size: 18,
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (target != null) {
      final isPickup =
          _target?.kind == _NavTargetKind.soloPickup ||
          (_target?.kind == _NavTargetKind.groupStop &&
              _currentStopIdx != null &&
              (_groupStopOrder.isNotEmpty
                  ? _groupStopOrder[_currentStopIdx!] < 2
                  : false));
      markers.add(_buildTargetMarker(target, isPickup));
    }
    final polylineColor = _routeError != null
        ? theme.colorScheme.outline
        : theme.colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: Text(_target?.label ?? 'Navigation'),
        actions: [
          IconButton(
            tooltip: 'Message rider',
            onPressed: _openChatForCurrentRide,
            icon: const Icon(Icons.chat_bubble_outline),
          ),
          IconButton(
            tooltip: 'Follow my location',
            onPressed: () {
              setState(() => _following = !_following);
              final posNow = _driverPosition;
              if (_following && posNow != null && _mapReady) {
                _mapController.move(
                  LatLng(posNow.latitude, posNow.longitude),
                  16,
                );
              }
            },
            icon: Icon(
              _following ? Icons.my_location : Icons.location_searching,
            ),
            color: _following ? theme.colorScheme.primary : null,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(3.1390, 101.6869),
              initialZoom: 13,
              minZoom: 4,
              maxZoom: 19,
              keepAlive: true,
              onMapReady: () {
                _mapReady = true;
                unawaited(_fitRoute());
              },
              onPointerDown: (_, _) {
                if (_following) setState(() => _following = false);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.infrago.infra_go',
              ),
              if (_polyline.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _polyline,
                      strokeWidth: 5,
                      color: polylineColor,
                      borderStrokeWidth: 2,
                      borderColor: theme.colorScheme.surface,
                    ),
                  ],
                ),
              MarkerLayer(markers: markers),
            ],
          ),
          if (_statusError != null)
            Positioned(
              top: AppSpacing.base,
              left: AppSpacing.marginMobile,
              right: AppSpacing.marginMobile,
              child: Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  child: Text('$_statusError'),
                ),
              ),
            ),
          Positioned(
            left: AppSpacing.marginMobile,
            right: AppSpacing.marginMobile,
            bottom: AppSpacing.marginMobile,
            child: _NavigationCard(
              target: _target,
              route: _routeResult,
              maneuver: maneuver,
              eta: eta,
              remainingMeters: remainingMeters,
              arrived: arrived,
              onMessageRider: _arrivedAction,
              onConfirmStop: _isGroup ? _confirmCurrentGroupStop : null,
              confirmStopLabel: _confirmStopLabel,
              confirmingStop: _advancingStop,
              lastFallback: _lastFallbackWasStraight,
              routeError: _routeError,
            ),
          ),
        ],
      ),
    );
  }

  Marker _buildTargetMarker(LatLng point, bool isPickup) {
    final riderSlot = _target?.riderSlot;
    final kind = _target?.kind ?? _NavTargetKind.soloPickup;
    final String badgeText;
    if (kind == _NavTargetKind.soloDestination) {
      badgeText = 'Destination';
    } else if (kind == _NavTargetKind.groupStop && riderSlot != null) {
      badgeText = _groupStopOrder.isNotEmpty && _currentStopIdx != null
          ? (_groupStopOrder[_currentStopIdx!] < 2
                ? 'P$riderSlot'
                : 'D$riderSlot')
          : 'P$riderSlot';
    } else {
      badgeText = 'Pickup';
    }
    final color = isPickup || kind == _NavTargetKind.soloPickup
        ? const Color(0xFF1DB173)
        : const Color(0xFFBA1A1A);
    final icon = isPickup || kind == _NavTargetKind.soloPickup
        ? Icons.trip_origin
        : Icons.location_pin;
    return Marker(
      point: point,
      width: 80,
      height: 80,
      alignment: Alignment.bottomCenter,
      child: Semantics(
        label: 'Navigation target $badgeText',
        child: Stack(
          alignment: Alignment.bottomCenter,
          clipBehavior: Clip.none,
          children: [
            Positioned(
              bottom: 0,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 22),
              ),
            ),
            Positioned(
              top: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: Text(
                  badgeText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Maneuver {
  const _Maneuver({
    required this.icon,
    required this.text,
    this.distanceMeters,
  });
  final IconData icon;
  final String text;
  final double? distanceMeters;
}

class _NavigationCard extends StatelessWidget {
  const _NavigationCard({
    required this.target,
    required this.route,
    required this.maneuver,
    required this.eta,
    required this.remainingMeters,
    required this.arrived,
    required this.onMessageRider,
    required this.onConfirmStop,
    required this.confirmStopLabel,
    required this.confirmingStop,
    required this.lastFallback,
    required this.routeError,
  });

  final _NavTarget? target;
  final RouteResult? route;
  final _Maneuver maneuver;
  final String eta;
  final double remainingMeters;
  final bool arrived;
  final VoidCallback onMessageRider;
  final VoidCallback? onConfirmStop;
  final String confirmStopLabel;
  final bool confirmingStop;
  final bool lastFallback;
  final String? routeError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final arrivedState = arrived && target != null;
    final cardColor = arrivedState
        ? theme.colorScheme.tertiaryContainer
        : lastFallback
        ? theme.colorScheme.surfaceContainerHigh
        : theme.colorScheme.primaryContainer.withValues(alpha: 0.85);
    final onCard = arrivedState
        ? theme.colorScheme.onTertiaryContainer
        : lastFallback
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onPrimaryContainer;
    final distanceStr = remainingMeters < 1000
        ? '${remainingMeters.round()} m'
        : '${(remainingMeters / 1000).toStringAsFixed(1)} km';
    final maneuverDistance = maneuver.distanceMeters;
    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      elevation: 6,
      shadowColor: Colors.black26,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.gutter,
          AppSpacing.gutter,
          AppSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (lastFallback) ...[
              Row(
                children: [
                  Icon(Icons.cloud_off, size: 14, color: onCard),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      'Straight-line guidance — routing service unavailable${routeError == null ? '.' : ': $routeError'}',
                      style: theme.textTheme.bodySmall?.copyWith(color: onCard),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            if (arrivedState) ...[
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.tertiary,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const Icon(Icons.check, color: Colors.white),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Arrived at ${target!.shortLabel}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: onCard,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          'Confirm arrival with the rider or tap below to send a quick message.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: onCard,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onMessageRider,
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('Send "I have arrived" quick update'),
                ),
              ),
              if (onConfirmStop != null) ...[
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: confirmingStop ? null : onConfirmStop,
                    icon: confirmingStop
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: Text(
                      confirmingStop ? 'Updating group…' : confirmStopLabel,
                    ),
                  ),
                ),
              ],
            ] else ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(maneuver.icon, size: 40, color: onCard),
                      if (maneuverDistance != null)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xs),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: onCard.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(
                                AppRadius.full,
                              ),
                            ),
                            child: Text(
                              maneuverDistance < 1000
                                  ? '${maneuverDistance.round()} m'
                                  : '${(maneuverDistance / 1000).toStringAsFixed(1)} km',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: onCard,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: AppSpacing.gutter),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          maneuver.text,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: onCard,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          target?.label ?? 'Loading navigation target…',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: onCard,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              const Divider(),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  _Fact(
                    icon: Icons.route,
                    label: 'Distance',
                    value: distanceStr,
                    color: onCard,
                  ),
                  const Spacer(),
                  _Fact(
                    icon: Icons.schedule,
                    label: 'ETA',
                    value: eta,
                    color: onCard,
                  ),
                  const Spacer(),
                  _Fact(
                    icon: Icons.flag_outlined,
                    label: 'Arrival',
                    value: arrivedState ? 'Now' : '< 50m',
                    color: onCard,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
