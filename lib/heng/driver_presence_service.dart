import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DriverPresenceException implements Exception {
  const DriverPresenceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DriverPresenceService {
  DriverPresenceService(this._client);

  final SupabaseClient _client;
  Timer? _timer;
  bool _publishing = false;
  LatLng? _lastKnownPosition;
  DateTime? _lastKnownPositionAt;

  bool get isRunning => _timer != null;
  LatLng? get lastKnownPosition => _lastKnownPosition;
  DateTime? get lastKnownPositionAt => _lastKnownPositionAt;
  bool get hasFreshPosition =>
      _lastKnownPosition != null &&
      _lastKnownPositionAt != null &&
      DateTime.now().difference(_lastKnownPositionAt!).abs().inSeconds <= 60;

  Future<void> start({required List<String> vehicleCategories}) async {
    await _ensurePermission();
    await _publish(vehicleCategories);
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => _publish(vehicleCategories),
    );
  }

  Future<void> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const DriverPresenceException(
        'Turn on location services to go online.',
      );
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const DriverPresenceException(
        'Location permission is required to go online.',
      );
    }
  }

  Future<void> startAssigned({required List<String> rideIds}) async {
    await _ensurePermission();
    await _publishExact(rideIds);
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _publishExact(rideIds),
    );
  }

  Future<void> _publish(List<String> vehicleCategories) async {
    if (_publishing) return;
    _publishing = true;
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      _lastKnownPosition = LatLng(position.latitude, position.longitude);
      _lastKnownPositionAt = DateTime.now();
      await _client.rpc(
        'upsert_my_driver_presence',
        params: {
          'p_coarse_lat': _coarse(position.latitude),
          'p_coarse_lng': _coarse(position.longitude),
          'p_vehicle_categories': vehicleCategories,
          'p_is_online': true,
          'p_is_assigned': false,
          'p_heading': position.heading.isFinite ? position.heading : null,
        },
      );
    } finally {
      _publishing = false;
    }
  }

  double _coarse(double value) => (value * 1000).round() / 1000;

  Future<void> _publishExact(List<String> rideIds) async {
    if (_publishing || rideIds.isEmpty) return;
    _publishing = true;
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      _lastKnownPosition = LatLng(position.latitude, position.longitude);
      _lastKnownPositionAt = DateTime.now();
      for (final rideId in rideIds) {
        await _client.rpc(
          'publish_assigned_driver_location',
          params: {
            'p_ride_id': rideId,
            'p_exact_lat': position.latitude,
            'p_exact_lng': position.longitude,
            'p_heading': position.heading.isFinite ? position.heading : null,
          },
        );
      }
    } finally {
      _publishing = false;
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _client.rpc('set_my_driver_offline');
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
