import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'app_theme.dart';
import 'booking_form_screen.dart';
import 'chat_with_driver_screen.dart';
import 'location_search_service.dart';
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

enum _MapEditTarget { pickup, destination }

class TripPlannerMapScreen extends StatefulWidget {
  const TripPlannerMapScreen({super.key});

  @override
  State<TripPlannerMapScreen> createState() => _TripPlannerMapScreenState();
}

class _TripPlannerMapScreenState extends State<TripPlannerMapScreen> {
  final MapController _mapController = MapController();
  final PhotonLocationSearchService _locationSearch =
      PhotonLocationSearchService();
  StreamSubscription<Position>? _positionSubscription;
  LatLng? _currentLocation;
  GeoPlace? _pickup;
  GeoPlace? _destination;
  String? _locationMessage;
  bool _isLocating = true;
  bool _isResolvingPin = false;
  bool _mapIsReady = false;
  _MapEditTarget _mapEditTarget = _MapEditTarget.destination;

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
        _setLocationFailure('Turn on location services to use your position.');
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
          'Location permission is blocked. Enable it in phone settings.',
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
              _setLocationFailure('Unable to update your location.');
            },
          );
    } catch (_) {
      _setLocationFailure('Unable to get your current location.');
    }
  }

  void _applyPosition(Position position, {bool moveMap = false}) {
    if (!mounted) {
      return;
    }
    final point = LatLng(position.latitude, position.longitude);
    final shouldSetPickup = _pickup == null;
    setState(() {
      _currentLocation = point;
      _isLocating = false;
      _locationMessage = null;
      if (shouldSetPickup) {
        _pickup = GeoPlace.coordinate(point, name: 'Current location');
      }
    });
    if (moveMap) {
      _moveTo(point);
    }
    if (shouldSetPickup) {
      unawaited(_resolvePin(point, _MapEditTarget.pickup));
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
    if (_mapIsReady) {
      _mapController.move(point, 16);
    }
  }

  void _focusSelectedPlaces(LatLng fallback) {
    if (!_mapIsReady) {
      return;
    }
    final pickup = _pickup;
    final destination = _destination;
    if (pickup == null || destination == null) {
      _moveTo(fallback);
      return;
    }
    _mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: [pickup.point, destination.point],
        padding: const EdgeInsets.fromLTRB(60, 260, 60, 150),
        maxZoom: 16,
      ),
    );
  }

  Future<void> _useCurrentLocation() async {
    final point = _currentLocation;
    if (point == null) {
      await _startLocationTracking();
      return;
    }
    setState(() {
      _pickup = GeoPlace.coordinate(point, name: 'Current location');
      _mapEditTarget = _MapEditTarget.destination;
    });
    _moveTo(point);
    await _resolvePin(point, _MapEditTarget.pickup);
  }

  void _selectPointOnMap(TapPosition _, LatLng point) {
    final target = _mapEditTarget;
    setState(() {
      final place = GeoPlace.coordinate(point);
      if (target == _MapEditTarget.pickup) {
        _pickup = place;
      } else {
        _destination = place;
      }
    });
    unawaited(_resolvePin(point, target));
  }

  Future<void> _resolvePin(LatLng point, _MapEditTarget target) async {
    if (mounted) {
      setState(() => _isResolvingPin = true);
    }
    try {
      final place = await _locationSearch.reverse(point);
      if (!mounted || place == null || !_targetStillAt(target, point)) {
        return;
      }
      setState(() {
        if (target == _MapEditTarget.pickup) {
          _pickup = place;
        } else {
          _destination = place;
        }
      });
    } on LocationSearchException {
      // Keep coordinates as a usable fallback when reverse lookup fails.
    } finally {
      if (mounted) {
        setState(() => _isResolvingPin = false);
      }
    }
  }

  bool _targetStillAt(_MapEditTarget target, LatLng point) {
    final selected = target == _MapEditTarget.pickup ? _pickup : _destination;
    return selected != null &&
        selected.point.latitude == point.latitude &&
        selected.point.longitude == point.longitude;
  }

  Future<void> _openPlaceSearch(_MapEditTarget target) async {
    final place = await showModalBottomSheet<GeoPlace>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _PlaceSearchSheet(
        title: target == _MapEditTarget.pickup
            ? 'Choose pickup point'
            : 'Where are you going?',
        hint: target == _MapEditTarget.pickup
            ? 'Search pickup location'
            : 'Search destination',
        searchService: _locationSearch,
        near: _currentLocation ?? _pickup?.point,
        currentLocation: target == _MapEditTarget.pickup
            ? _currentLocation
            : null,
      ),
    );
    if (place == null || !mounted) {
      return;
    }

    setState(() {
      if (target == _MapEditTarget.pickup) {
        _pickup = place;
        _mapEditTarget = _MapEditTarget.destination;
      } else {
        _destination = place;
        _mapEditTarget = _MapEditTarget.destination;
      }
    });
    _focusSelectedPlaces(place.point);
  }

  void _reviewTrip() {
    final pickup = _pickup;
    final destination = _destination;
    if (pickup == null || destination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose pickup and destination first.')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            TripPlanReviewScreen(pickup: pickup, destination: destination),
      ),
    );
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _locationSearch.close();
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final riderId = supabase.auth.currentUser?.id;
    final pickup = _pickup;
    final destination = _destination;
    final distance = pickup != null && destination != null
        ? straightLineDistanceMeters(pickup.point, destination.point)
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Plan a ride')),
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
              onTap: _selectPointOnMap,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.infrago.infra_go',
              ),
              if (pickup != null && destination != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [pickup.point, destination.point],
                      strokeWidth: 5,
                      color: Theme.of(context).colorScheme.secondary,
                      borderStrokeWidth: 2,
                      borderColor: Theme.of(context).colorScheme.surface,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (_currentLocation != null)
                    Marker(
                      point: _currentLocation!,
                      width: 24,
                      height: 24,
                      child: const _CurrentLocationDot(),
                    ),
                  if (pickup != null)
                    Marker(
                      point: pickup.point,
                      width: 48,
                      height: 48,
                      alignment: Alignment.bottomCenter,
                      child: const _MapPin(
                        color: Color(0xFF1DB173),
                        icon: Icons.trip_origin,
                        label: 'Pickup point',
                      ),
                    ),
                  if (destination != null)
                    Marker(
                      point: destination.point,
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
            ],
          ),
          Positioned(
            left: AppSpacing.sm,
            right: AppSpacing.sm,
            top: AppSpacing.sm,
            child: _RideSearchCard(
              pickup: pickup,
              destination: destination,
              isLocating: _isLocating,
              locationMessage: _locationMessage,
              mapEditTarget: _mapEditTarget,
              onSearchPickup: () => _openPlaceSearch(_MapEditTarget.pickup),
              onSearchDestination: () =>
                  _openPlaceSearch(_MapEditTarget.destination),
              onUseCurrentLocation: _useCurrentLocation,
              onMapEditTargetChanged: (target) {
                setState(() => _mapEditTarget = target);
              },
            ),
          ),
          if (riderId != null)
            Positioned(
              left: AppSpacing.sm,
              right: AppSpacing.sm,
              top: 205,
              child: _ActiveRidePanel(riderId: riderId),
            ),
          Positioned(
            right: AppSpacing.gutter,
            bottom: 190,
            child: FloatingActionButton.small(
              heroTag: 'currentLocation',
              onPressed: _currentLocation == null
                  ? _startLocationTracking
                  : () => _moveTo(_currentLocation!),
              tooltip: _currentLocation == null
                  ? 'Retry location'
                  : 'Centre on my location',
              child: Icon(
                _currentLocation == null
                    ? Icons.location_searching
                    : Icons.my_location,
              ),
            ),
          ),
          Positioned(
            left: AppSpacing.base,
            bottom: 176,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: const Padding(
                padding: EdgeInsets.all(AppSpacing.xs),
                child: Text(
                  '© OpenStreetMap contributors · Search by Photon',
                  style: TextStyle(fontSize: 10),
                ),
              ),
            ),
          ),
          Positioned(
            left: AppSpacing.sm,
            right: AppSpacing.sm,
            bottom: 30,
            child: _TripSummaryPanel(
              pickup: pickup,
              destination: destination,
              distanceMeters: distance,
              isResolvingPin: _isResolvingPin,
              onReviewTrip: _reviewTrip,
            ),
          ),
        ],
      ),
    );
  }
}

class _RideSearchCard extends StatelessWidget {
  const _RideSearchCard({
    required this.pickup,
    required this.destination,
    required this.isLocating,
    required this.locationMessage,
    required this.mapEditTarget,
    required this.onSearchPickup,
    required this.onSearchDestination,
    required this.onUseCurrentLocation,
    required this.onMapEditTargetChanged,
  });

  final GeoPlace? pickup;
  final GeoPlace? destination;
  final bool isLocating;
  final String? locationMessage;
  final _MapEditTarget mapEditTarget;
  final VoidCallback onSearchPickup;
  final VoidCallback onSearchDestination;
  final VoidCallback onUseCurrentLocation;
  final ValueChanged<_MapEditTarget> onMapEditTargetChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LocationSearchField(
              icon: Icons.trip_origin,
              iconColor: const Color(0xFF1DB173),
              label: 'Pickup',
              value: isLocating
                  ? 'Finding your current location…'
                  : pickup?.bookingLabel ?? 'Choose pickup point',
              onTap: onSearchPickup,
              trailing: IconButton(
                onPressed: onUseCurrentLocation,
                tooltip: 'Use current location',
                icon: const Icon(Icons.my_location, size: 20),
              ),
            ),
            const SizedBox(height: AppSpacing.base),
            _LocationSearchField(
              icon: Icons.location_pin,
              iconColor: Theme.of(context).colorScheme.error,
              label: 'Destination',
              value: destination?.bookingLabel ?? 'Where are you going?',
              onTap: onSearchDestination,
            ),
            if (locationMessage != null) ...[
              const SizedBox(height: AppSpacing.base),
              Row(
                children: [
                  const Icon(Icons.info_outline, size: 16),
                  const SizedBox(width: AppSpacing.base),
                  Expanded(
                    child: Text(
                      locationMessage!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.base),
            Row(
              children: [
                Text(
                  'Tap map to adjust:',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: AppSpacing.base),
                Expanded(
                  child: SegmentedButton<_MapEditTarget>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: _MapEditTarget.pickup,
                        label: Text('Pickup'),
                      ),
                      ButtonSegment(
                        value: _MapEditTarget.destination,
                        label: Text('Drop-off'),
                      ),
                    ],
                    selected: {mapEditTarget},
                    onSelectionChanged: (selection) {
                      onMapEditTargetChanged(selection.first);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LocationSearchField extends StatelessWidget {
  const _LocationSearchField({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppRadius.standard),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.standard),
        child: Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.sm,
            top: AppSpacing.base,
            bottom: AppSpacing.base,
          ),
          child: Row(
            children: [
              Icon(icon, color: iconColor, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: AppTextStyles.labelCaps),
                    Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              trailing ?? const SizedBox(width: AppSpacing.sm),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaceSearchSheet extends StatefulWidget {
  const _PlaceSearchSheet({
    required this.title,
    required this.hint,
    required this.searchService,
    required this.near,
    required this.currentLocation,
  });

  final String title;
  final String hint;
  final PhotonLocationSearchService searchService;
  final LatLng? near;
  final LatLng? currentLocation;

  @override
  State<_PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<_PlaceSearchSheet> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  List<GeoPlace> _results = const [];
  bool _isSearching = false;
  String? _error;
  int _requestNumber = 0;

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 3) {
      setState(() {
        _results = const [];
        _isSearching = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 650), () {
      _search(query);
    });
  }

  Future<void> _search(String query) async {
    final requestNumber = ++_requestNumber;
    setState(() {
      _isSearching = true;
      _error = null;
    });
    try {
      final results = await widget.searchService.search(
        query,
        near: widget.near,
      );
      if (!mounted || requestNumber != _requestNumber) {
        return;
      }
      setState(() => _results = results);
    } on LocationSearchException catch (error) {
      if (!mounted || requestNumber != _requestNumber) {
        return;
      }
      setState(() {
        _results = const [];
        _error = error.message;
      });
    } finally {
      if (mounted && requestNumber == _requestNumber) {
        setState(() => _isSearching = false);
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.gutter,
        right: AppSpacing.gutter,
        top: AppSpacing.gutter,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.gutter,
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              onSubmitted: (value) {
                _debounce?.cancel();
                if (value.trim().length >= 3) {
                  _search(value.trim());
                }
              },
              decoration: InputDecoration(
                hintText: widget.hint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _isSearching
                    ? const Padding(
                        padding: EdgeInsets.all(AppSpacing.sm),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
            ),
            if (widget.currentLocation != null) ...[
              const SizedBox(height: AppSpacing.base),
              ListTile(
                leading: const Icon(Icons.my_location),
                title: const Text('Use my current location'),
                onTap: () => Navigator.pop(
                  context,
                  GeoPlace.coordinate(
                    widget.currentLocation!,
                    name: 'Current location',
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.base),
            Expanded(child: _buildResults(context)),
            const Divider(),
            const Text(
              'Location search powered by Photon · Data © OpenStreetMap contributors',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    if (_controller.text.trim().length < 3) {
      return const Center(
        child: Text('Type at least 3 characters to search nearby places.'),
      );
    }
    if (_isSearching && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return const Center(child: Text('No matching places found.'));
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final place = _results[index];
        return ListTile(
          leading: const Icon(Icons.place_outlined),
          title: Text(place.name),
          subtitle: place.subtitle.isEmpty
              ? null
              : Text(
                  place.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          onTap: () => Navigator.pop(context, place),
        );
      },
    );
  }
}

class _TripSummaryPanel extends StatelessWidget {
  const _TripSummaryPanel({
    required this.pickup,
    required this.destination,
    required this.distanceMeters,
    required this.isResolvingPin,
    required this.onReviewTrip,
  });

  final GeoPlace? pickup;
  final GeoPlace? destination;
  final double? distanceMeters;
  final bool isResolvingPin;
  final VoidCallback onReviewTrip;

  @override
  Widget build(BuildContext context) {
    final canContinue = pickup != null && destination != null;
    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    canContinue ? 'Trip ready' : 'Choose a destination',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    isResolvingPin
                        ? 'Finding address…'
                        : distanceMeters == null
                        ? 'Search above or tap the map to place a pin.'
                        : '${(distanceMeters! / 1000).toStringAsFixed(2)} km straight-line preview',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            ElevatedButton(
              onPressed: canContinue ? onReviewTrip : null,
              child: const Text('Review'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentLocationDot extends StatelessWidget {
  const _CurrentLocationDot();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.blue,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 5)],
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
          return const SizedBox.shrink();
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
        return Card(
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.local_taxi),
            title: Text(
              '${activeRide.pickup} → ${activeRide.destination}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('Status: ${activeRide.status.replaceAll('_', ' ')}'),
            trailing: canChat
                ? IconButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              ChatWithDriverScreen(rideId: activeRide.id),
                        ),
                      );
                    },
                    tooltip: 'Chat with driver',
                    icon: const Icon(Icons.chat_bubble_outline),
                  )
                : null,
          ),
        );
      },
    );
  }
}

class TripPlanReviewScreen extends StatelessWidget {
  const TripPlanReviewScreen({
    super.key,
    required this.pickup,
    required this.destination,
  });

  final GeoPlace pickup;
  final GeoPlace destination;

  void _openBookingSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => BookingFormSheet(
        initialPickup: pickup.bookingLabel,
        initialDestination: destination.bookingLabel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final distance = straightLineDistanceMeters(
      pickup.point,
      destination.point,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Review trip')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.marginMobile),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('TRIP DETAILS', style: AppTextStyles.labelCaps),
            const SizedBox(height: AppSpacing.gutter),
            _LocationSummary(
              icon: Icons.trip_origin,
              iconColor: const Color(0xFF1DB173),
              label: 'Pickup',
              place: pickup,
            ),
            const Padding(
              padding: EdgeInsets.only(left: 11),
              child: SizedBox(
                height: 28,
                child: VerticalDivider(width: 2, thickness: 2),
              ),
            ),
            _LocationSummary(
              icon: Icons.location_pin,
              iconColor: Theme.of(context).colorScheme.error,
              label: 'Destination',
              place: destination,
            ),
            const SizedBox(height: AppSpacing.md),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.gutter),
                child: Row(
                  children: [
                    const Icon(Icons.route),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${(distance / 1000).toStringAsFixed(2)} km',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Text(
                            'Straight-line estimate; road distance may differ.',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            ElevatedButton.icon(
              onPressed: () => _openBookingSheet(context),
              icon: const Icon(Icons.local_taxi),
              label: const Text('Confirm ride details'),
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
    required this.iconColor,
    required this.label,
    required this.place,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final GeoPlace place;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: iconColor),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppTextStyles.labelCaps),
              const SizedBox(height: AppSpacing.xs),
              Text(place.name, style: Theme.of(context).textTheme.titleMedium),
              if (place.subtitle.isNotEmpty)
                Text(
                  place.subtitle,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
