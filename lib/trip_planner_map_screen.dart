import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'app_theme.dart';
import 'booking_form_screen.dart';
import 'chat_with_driver_screen.dart';
import 'ride.dart';
import 'supabase_config.dart';

const LatLng kKualaLumpurCenter = LatLng(3.1390, 101.6869);

String formatCoordinate(LatLng point) =>
    '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';

double straightLineDistanceMeters(LatLng origin, LatLng destination) =>
    Geolocator.distanceBetween(
      origin.latitude,
      origin.longitude,
      destination.latitude,
      destination.longitude,
    );

class TripPlannerMapScreen extends StatefulWidget {
  const TripPlannerMapScreen({super.key, this.riderId});

  final String? riderId;

  @override
  State<TripPlannerMapScreen> createState() => _TripPlannerMapScreenState();
}

class _TripPlannerMapScreenState extends State<TripPlannerMapScreen> {
  final MapController _mapController = MapController();
  StreamSubscription<Position>? _positionSubscription;
  LatLng? _currentLocation;
  LatLng? _destination;
  String? _locationMessage;
  bool _isLocating = true;
  bool _mapIsReady = false;

  @override
  void initState() {
    super.initState();
    _startLocationTracking();
  }

  Future<void> _startLocationTracking() async {
    await _positionSubscription?.cancel();
    if (mounted) {
      setState(() {
        _isLocating = true;
        _locationMessage = null;
      });
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _setLocationFailure('Location services are disabled.');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        _setLocationFailure('Location permission was denied.');
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        _setLocationFailure(
          'Location permission is permanently denied. Enable it in settings.',
        );
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      _applyPosition(position, moveMap: true);

      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            ),
          ).listen(
            _applyPosition,
            onError: (Object error) {
              _setLocationFailure('Unable to update location: $error');
            },
          );
    } catch (error) {
      _setLocationFailure('Unable to get current location: $error');
    }
  }

  void _applyPosition(Position position, {bool moveMap = false}) {
    if (!mounted) {
      return;
    }
    final point = LatLng(position.latitude, position.longitude);
    setState(() {
      _currentLocation = point;
      _isLocating = false;
      _locationMessage = null;
    });
    if (moveMap) {
      _moveTo(point);
    }
  }

  void _setLocationFailure(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _isLocating = false;
      _locationMessage = message;
    });
  }

  void _moveTo(LatLng point) {
    if (!_mapIsReady) {
      return;
    }
    _mapController.move(point, 16);
  }

  void _selectDestination(TapPosition _, LatLng point) {
    setState(() {
      _destination = point;
    });
  }

  void _reviewTrip() {
    final origin = _currentLocation;
    final destination = _destination;
    if (origin == null || destination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Wait for your location and tap the map to choose a destination.',
          ),
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            TripPlanReviewScreen(origin: origin, destination: destination),
      ),
    );
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final riderId = widget.riderId ?? supabase.auth.currentUser!.id;
    final currentLocation = _currentLocation;
    final destination = _destination;
    final distance = currentLocation != null && destination != null
        ? straightLineDistanceMeters(currentLocation, destination)
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Trip Planner & Map')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: kKualaLumpurCenter,
              initialZoom: 13,
              minZoom: 4,
              maxZoom: 19,
              keepAlive: true,
              onMapReady: () {
                _mapIsReady = true;
                final point = _currentLocation;
                if (point != null) {
                  _moveTo(point);
                }
              },
              onTap: _selectDestination,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.infrago.infra_go',
              ),
              if (currentLocation != null && destination != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [currentLocation, destination],
                      strokeWidth: 5,
                      color: Theme.of(context).colorScheme.secondary,
                      borderStrokeWidth: 2,
                      borderColor: Theme.of(context).colorScheme.surface,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (currentLocation != null)
                    Marker(
                      point: currentLocation,
                      width: 48,
                      height: 48,
                      child: _MapPin(
                        color: Theme.of(context).colorScheme.primary,
                        icon: Icons.my_location,
                        label: 'Your location',
                      ),
                    ),
                  if (destination != null)
                    Marker(
                      point: destination,
                      width: 48,
                      height: 48,
                      alignment: Alignment.bottomCenter,
                      child: _MapPin(
                        color: Theme.of(context).colorScheme.error,
                        icon: Icons.location_pin,
                        label: 'Destination',
                      ),
                    ),
                ],
              ),
              const SimpleAttributionWidget(
                source: Text('OpenStreetMap contributors'),
                alignment: Alignment.bottomLeft,
              ),
            ],
          ),
          Positioned(
            left: AppSpacing.sm,
            right: AppSpacing.sm,
            top: AppSpacing.sm,
            child: _ActiveRidePanel(riderId: riderId),
          ),
          Positioned(
            right: AppSpacing.gutter,
            bottom: 230,
            child: FloatingActionButton.small(
              heroTag: 'currentLocation',
              onPressed: currentLocation == null
                  ? _startLocationTracking
                  : () => _moveTo(currentLocation),
              tooltip: currentLocation == null
                  ? 'Retry location'
                  : 'Centre on my location',
              child: Icon(
                currentLocation == null
                    ? Icons.location_searching
                    : Icons.my_location,
              ),
            ),
          ),
          Positioned(
            left: AppSpacing.sm,
            right: AppSpacing.sm,
            bottom: 38,
            child: _TripSelectionPanel(
              currentLocation: currentLocation,
              destination: destination,
              distanceMeters: distance,
              isLocating: _isLocating,
              locationMessage: _locationMessage,
              onRetryLocation: _startLocationTracking,
              onClearDestination: destination == null
                  ? null
                  : () {
                      setState(() {
                        _destination = null;
                      });
                    },
              onReviewTrip: _reviewTrip,
            ),
          ),
        ],
      ),
    );
  }
}

class _MapPin extends StatelessWidget {
  const _MapPin({required this.color, required this.icon, required this.label});

  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: DecoratedBox(
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
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }
}

class _ActiveRidePanel extends StatelessWidget {
  const _ActiveRidePanel({required this.riderId});

  final String riderId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: supabase
          .from('rides')
          .stream(primaryKey: ['id'])
          .eq('rider_id', riderId)
          .order('created_at'),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _StatusCard(
            icon: Icons.cloud_off,
            title: 'Ride status unavailable',
            subtitle: snapshot.error.toString(),
          );
        }

        final rides = (snapshot.data ?? [])
            .map(Ride.fromJson)
            .where(
              (ride) =>
                  ride.status != 'completed' && ride.status != 'cancelled',
            )
            .toList();
        if (rides.isEmpty) {
          return const SizedBox.shrink();
        }

        final activeRide = rides.last;
        final canChat =
            activeRide.status == 'matched' || activeRide.status == 'en_route';
        return _StatusCard(
          icon: Icons.local_taxi,
          title: '${activeRide.pickup} → ${activeRide.destination}',
          subtitle: 'Status: ${activeRide.status.replaceAll('_', ' ')}',
          action: canChat
              ? TextButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            ChatWithDriverScreen(rideId: activeRide.id),
                      ),
                    );
                  },
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('Chat'),
                )
              : null,
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          children: [
            Icon(icon),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            action ?? const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}

class _TripSelectionPanel extends StatelessWidget {
  const _TripSelectionPanel({
    required this.currentLocation,
    required this.destination,
    required this.distanceMeters,
    required this.isLocating,
    required this.locationMessage,
    required this.onRetryLocation,
    required this.onClearDestination,
    required this.onReviewTrip,
  });

  final LatLng? currentLocation;
  final LatLng? destination;
  final double? distanceMeters;
  final bool isLocating;
  final String? locationMessage;
  final VoidCallback onRetryLocation;
  final VoidCallback? onClearDestination;
  final VoidCallback onReviewTrip;

  @override
  Widget build(BuildContext context) {
    final locationText = isLocating
        ? 'Getting your current location…'
        : locationMessage ??
              (currentLocation == null
                  ? 'Current location unavailable'
                  : 'Pickup: ${formatCoordinate(currentLocation!)}');
    final destinationText = destination == null
        ? 'Tap anywhere on the map to choose a destination.'
        : 'Destination: ${formatCoordinate(destination!)}';
    final distanceText = distanceMeters == null
        ? null
        : 'Straight-line preview: ${(distanceMeters! / 1000).toStringAsFixed(2)} km';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (isLocating)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.trip_origin, size: 18),
                const SizedBox(width: AppSpacing.base),
                Expanded(child: Text(locationText, maxLines: 2)),
                if (locationMessage != null)
                  IconButton(
                    onPressed: onRetryLocation,
                    tooltip: 'Retry location',
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.base),
            Text(destinationText),
            if (distanceText != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(distanceText, style: AppTextStyles.labelCaps),
            ],
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                TextButton.icon(
                  onPressed: onClearDestination,
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear'),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: currentLocation != null && destination != null
                      ? onReviewTrip
                      : null,
                  icon: const Icon(Icons.route),
                  label: const Text('Review trip'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TripPlanReviewScreen extends StatelessWidget {
  const TripPlanReviewScreen({
    super.key,
    required this.origin,
    required this.destination,
  });

  final LatLng origin;
  final LatLng destination;

  void _openBookingSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => BookingFormSheet(
        initialPickup: formatCoordinate(origin),
        initialDestination: formatCoordinate(destination),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final distance = straightLineDistanceMeters(origin, destination);
    return Scaffold(
      appBar: AppBar(title: const Text('Review Trip')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.marginMobile),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('TRIP PLAN', style: AppTextStyles.labelCaps),
            const SizedBox(height: AppSpacing.gutter),
            _LocationSummary(
              icon: Icons.my_location,
              label: 'Pickup',
              value: formatCoordinate(origin),
            ),
            const SizedBox(height: AppSpacing.gutter),
            _LocationSummary(
              icon: Icons.location_pin,
              label: 'Destination',
              value: formatCoordinate(destination),
            ),
            const SizedBox(height: AppSpacing.md),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.gutter),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Distance preview', style: AppTextStyles.labelCaps),
                    const SizedBox(height: AppSpacing.base),
                    Text(
                      '${(distance / 1000).toStringAsFixed(2)} km',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: AppSpacing.base),
                    const Text(
                      'This is a straight-line preview. The driver follows the actual road route.',
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () => _openBookingSheet(context),
              icon: const Icon(Icons.local_taxi),
              label: const Text('Continue to Booking'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationSummary extends StatelessWidget {
  const _LocationSummary({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppTextStyles.labelCaps),
              const SizedBox(height: AppSpacing.xs),
              SelectableText(value),
            ],
          ),
        ),
      ],
    );
  }
}
