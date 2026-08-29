import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'app_theme.dart';
import 'booking_form_screen.dart';
import 'carpool_matcher.dart';
import 'chat_with_driver_screen.dart';
import 'driver_assigned_panel.dart';
import 'location_search_service.dart';
import 'osrm_routing_service.dart';
import 'pickup_confirmation_sheet.dart';
import 'ride.dart';
import 'shared_route_markers.dart';
import 'supabase_carpool_service.dart';
import 'supabase_config.dart';
import 'transit_stop_repository.dart';
import 'trip_planner_repository.dart';
import 'trip_planner_state.dart';
import 'vehicle_options_sheet.dart';
import 'vehicle_presence_service.dart';

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

enum _TransitStatus { idle, loading, data, empty, error }

class TripPlannerMapScreen extends StatefulWidget {
  const TripPlannerMapScreen({super.key});

  @override
  State<TripPlannerMapScreen> createState() => _TripPlannerMapScreenState();
}

class _TripPlannerMapScreenState extends State<TripPlannerMapScreen> {
  final MapController _mapController = MapController();
  final PhotonLocationSearchService _locationSearch =
      PhotonLocationSearchService();
  final OsrmRoutingService _routing = OsrmRoutingService();
  late final TripPlannerState _state;
  late final VehiclePresenceService _presence;

  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<List<CoarseVehicle>>? _nearbySubscription;
  StreamSubscription<RideLifecycleSnapshot>? _assignedSubscription;
  StreamSubscription<ExactDriver?>? _exactDriverSubscription;

  LatLng? _currentLocation;
  String? _locationMessage;
  bool _isLocating = true;
  bool _isResolvingPin = false;
  bool _mapIsReady = false;
  _MapEditTarget _mapEditTarget = _MapEditTarget.destination;

  List<CoarseVehicle> _nearby = const [];
  _TransitStatus _transitStatus = _TransitStatus.idle;
  List<NearbyTransitStop> _nearbyStops = const [];
  String? _transitError;
  CarpoolMatch? _currentMatch;
  late final TripPlannerRepository _tripRepository;
  late final SupabaseCarpoolService _carpoolService;
  late final TransitStopRepository _transitRepository;
  String _presenceCategory = 'economy_4';

  @override
  void initState() {
    super.initState();
    _state = TripPlannerState(routing: _routing, search: _locationSearch);
    _state.addListener(_onStateChanged);
    _state.onRequestSubmitted(_handleRequestSubmitted);
    _state.onCancelRequested(_handleCancelled);
    _tripRepository = SupabaseTripPlannerRepository(supabase);
    _carpoolService = SupabaseCarpoolService(
      client: supabase,
      matcher: CarpoolMatcher(routing: OsrmCarpoolRouting(_routing)),
    );
    _transitRepository = DatabaseTransitStopRepository(
      () async => List<Map<String, dynamic>>.from(
        await supabase.from('transit_stops').select(),
      ),
    );
    _presence = VehiclePresenceService(
      coarseFactory: (_) => supabase
          .from('nearby_driver_presence')
          .stream(primaryKey: ['anonymised_id']),
      exactFactory: (rideId) => supabase
          .from('assigned_driver_location')
          .stream(primaryKey: ['ride_id'])
          .eq('ride_id', rideId)
          .map((rows) => rows.isEmpty ? null : rows.first),
    );
    _startLocationTracking();
  }

  void _onStateChanged() {
    if (!mounted) return;
    final phase = _state.phase;
    setState(() {
      if (phase == TripPlannerPhase.explore ||
          phase == TripPlannerPhase.cancelled) {
        _currentMatch = null;
      }
    });
    if (phase == TripPlannerPhase.vehicleOptions &&
        _state.selectedVehicle == null) {
      unawaited(_openVehicleOptionsSheet());
    }
    if (phase == TripPlannerPhase.pickupConfirmation) {
      unawaited(_openPickupConfirmationSheet());
    }
  }

  Future<void> _handleRequestSubmitted() async {
    final pickup = _state.pickup;
    final destination = _state.destination;
    final vehicle = _state.selectedVehicle;
    final route = _state.route;
    final userId = supabase.auth.currentUser?.id;
    if (pickup == null ||
        destination == null ||
        vehicle == null ||
        route == null ||
        userId == null) {
      throw const TripPlannerRepositoryException(
        'Sign in and complete the trip before requesting a ride.',
      );
    }
    final rideId = await _tripRepository.createRide(
      RideDraft(
        riderId: userId,
        pickupLabel: pickup.bookingLabel,
        destinationLabel: destination.bookingLabel,
        pickup: pickup.point,
        destination: destination.point,
        serviceType: _databaseServiceType(vehicle),
        passengerCount: _state.passengerCount,
        departureTime: _state.effectiveDeparture,
        routeDistanceMeters: route.distanceMeters,
        routeDurationSeconds: route.durationSeconds,
        pickupNote: _state.pickupNote,
        estimatedSoloFare: vehicle.isShared ? null : vehicle.estimatedFareMin,
        estimatedSharedFare: vehicle.isShared ? vehicle.estimatedFareMin : null,
      ),
    );
    _state.setActiveRideId(rideId);
    _watchRide(rideId);
    if (vehicle.isShared) unawaited(_trySharedMatch(rideId));
  }

  String _databaseServiceType(VehicleOption vehicle) {
    if (vehicle.isShared) return 'shared_economy';
    return vehicle.id == 'six_seater' || vehicle.id == 'suv'
        ? 'six_seater'
        : 'economy_4';
  }

  void _handleCancelled() {
    _nearbySubscription?.cancel();
    _assignedSubscription?.cancel();
    _exactDriverSubscription?.cancel();
  }

  void _watchRide(String rideId) {
    _assignedSubscription?.cancel();
    _assignedSubscription = _tripRepository
        .watchRide(rideId)
        .listen(
          (snapshot) async {
            if (!mounted) return;
            switch (snapshot.status) {
              case 'matched':
              case 'driver_assigned':
                final driverId = snapshot.driverId;
                if (driverId != null) {
                  await _showAssignedDriver(rideId, driverId);
                }
              case 'en_route':
                final driverId = snapshot.driverId;
                if (_state.assignedDriver == null && driverId != null) {
                  await _showAssignedDriver(rideId, driverId);
                }
                _state.markEnRoute();
              case 'completed':
                _state.markCompleted();
              case 'cancelled':
                _state.markCancelledFromServer(reason: 'Ride cancelled');
              case 'requested':
              case 'waiting_match':
              default:
                break;
            }
          },
          onError: (Object error) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Ride updates unavailable: $error')),
            );
          },
        );
  }

  Future<void> _showAssignedDriver(String rideId, String driverId) async {
    try {
      final driver = await _tripRepository.loadAssignedDriver(driverId);
      if (!mounted || _state.activeRideId != rideId) return;
      _state.markDriverAssigned(driver);
      await _exactDriverSubscription?.cancel();
      _exactDriverSubscription = _presence.exactAssigned(rideId: rideId).listen(
        (exact) {
          final current = _state.assignedDriver;
          if (!mounted || exact == null || current == null) return;
          _state.markDriverAssigned(
            AssignedDriverInfo(
              driverId: current.driverId,
              name: current.name,
              rating: current.rating,
              vehicleMake: current.vehicleMake,
              vehicleModel: current.vehicleModel,
              vehiclePlate: exact.vehiclePlate,
              vehicleColor: current.vehicleColor,
              etaMinutes: current.etaMinutes,
              exactLocation: exact.exactLocation,
              phoneLastFour: current.phoneLastFour,
            ),
          );
        },
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Driver details unavailable: $error')),
      );
    }
  }

  Future<void> _trySharedMatch(String rideId) async {
    final pickup = _state.pickup;
    final destination = _state.destination;
    final userId = supabase.auth.currentUser?.id;
    if (pickup == null || destination == null || userId == null) return;
    final request = RideRequest(
      id: rideId,
      riderId: userId,
      pickup: pickup.point,
      destination: destination.point,
      departAt: _state.effectiveDeparture,
      passengers: _state.passengerCount,
    );
    try {
      final matches = await _carpoolService.findMatches(request);
      if (!mounted || matches.isEmpty || _state.activeRideId != rideId) return;
      final match = matches.first;
      final accepted = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) => SharedRouteMarkers.buildMatchBottomSheet(
          context: sheetContext,
          match: match,
          myRiderIndex: 0,
          onAccept: () => Navigator.pop(sheetContext, true),
          onDismiss: () => Navigator.pop(sheetContext, false),
        ),
      );
      if (accepted != true || !mounted) return;
      await _carpoolService.commitMatch(match);
      if (!mounted) return;
      setState(() => _currentMatch = match);
      _focusSelectedPlaces(pickup.point);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Shared ride matched · score ${match.score}/100'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Shared matching is still searching: $error')),
      );
    }
  }

  Future<void> _cancelActiveRide() async {
    final rideId = _state.activeRideId;
    if (rideId == null) return;
    try {
      await _tripRepository.cancelRide(rideId, reason: 'Rider cancelled');
      if (!mounted) return;
      _state.cancelCurrentFlow(reason: 'Rider cancelled');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Ride cancelled.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not cancel ride: $error')));
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _nearbySubscription?.cancel();
    _assignedSubscription?.cancel();
    _exactDriverSubscription?.cancel();
    _state.removeListener(_onStateChanged);
    _state.dispose();
    _locationSearch.close();
    _routing.close();
    _mapController.dispose();
    super.dispose();
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
    if (!mounted) return;
    final point = LatLng(position.latitude, position.longitude);
    final shouldSetPickup = _state.pickup == null;
    setState(() {
      _currentLocation = point;
      _isLocating = false;
      _locationMessage = null;
    });
    if (shouldSetPickup) {
      final place = GeoPlace.coordinate(point, name: 'Current location');
      _state.setPickup(place);
      unawaited(_resolvePin(point, _MapEditTarget.pickup));
    }
    if (moveMap) _moveTo(point);
    _subscribeNearby(point);
  }

  void _subscribeNearby(LatLng center) {
    _nearbySubscription?.cancel();
    _nearbySubscription = _presence
        .nearbyCoarse(
          center: center,
          category: _presenceCategory,
          radiusMeters: 2000,
        )
        .listen(
          (list) {
            if (!mounted) return;
            setState(() => _nearby = list);
          },
          onError: (_) {
            if (mounted) setState(() => _nearby = const []);
          },
        );
  }

  void _setLocationFailure(String message) {
    if (!mounted) return;
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
    if (!_mapIsReady) return;
    final pickup = _state.pickup;
    final destination = _state.destination;
    if (pickup == null || destination == null) {
      _moveTo(fallback);
      return;
    }
    final points = <LatLng>[pickup.point, destination.point];
    final routePts = _state.route?.points;
    if (routePts != null && routePts.isNotEmpty) {
      points.addAll(routePts);
    }
    _mapController.fitCamera(
      CameraFit.coordinates(
        coordinates: points,
        padding: const EdgeInsets.fromLTRB(60, 260, 60, 280),
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
    final place = GeoPlace.coordinate(point, name: 'Current location');
    _state.setPickup(place);
    setState(() => _mapEditTarget = _MapEditTarget.destination);
    _moveTo(point);
    await _resolvePin(point, _MapEditTarget.pickup);
  }

  void _selectPointOnMap(TapPosition _, LatLng point) {
    final target = _mapEditTarget;
    final place = GeoPlace.coordinate(point);
    if (target == _MapEditTarget.pickup) {
      _state.setPickup(place);
    } else {
      _state.setDestination(place);
    }
    unawaited(_resolvePin(point, target));
  }

  Future<void> _resolvePin(LatLng point, _MapEditTarget target) async {
    if (mounted) setState(() => _isResolvingPin = true);
    try {
      final place = await _locationSearch.reverse(point);
      if (!mounted || place == null) return;
      final current = target == _MapEditTarget.pickup
          ? _state.pickup
          : _state.destination;
      if (current == null ||
          (current.point.latitude == point.latitude &&
              current.point.longitude == point.longitude)) {
        if (target == _MapEditTarget.pickup) {
          _state.setPickup(place);
        } else {
          _state.setDestination(place);
        }
      }
    } on LocationSearchException {
    } finally {
      if (mounted) setState(() => _isResolvingPin = false);
    }
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
        near: _currentLocation ?? _state.pickup?.point,
        currentLocation: target == _MapEditTarget.pickup
            ? _currentLocation
            : null,
      ),
    );
    if (place == null || !mounted) return;
    if (target == _MapEditTarget.pickup) {
      _state.setPickup(place);
      setState(() => _mapEditTarget = _MapEditTarget.destination);
    } else {
      _state.setDestination(place);
      setState(() => _mapEditTarget = _MapEditTarget.destination);
    }
    _focusSelectedPlaces(place.point);
  }

  Future<void> _openVehicleOptionsSheet() async {
    final route = _state.route;
    final options = [
      const VehicleOption(
        id: 'economy_4',
        name: 'Economy',
        seats: 4,
        estimatedFareMin: 8.0,
        estimatedFareMax: 12.0,
      ),
      const VehicleOption(
        id: 'shared_economy',
        name: 'Shared Economy',
        seats: 4,
        estimatedFareMin: 5.0,
        estimatedFareMax: 8.0,
        isShared: true,
      ),
      const VehicleOption(
        id: 'six_seater',
        name: 'SUV / 6-seater',
        seats: 6,
        estimatedFareMin: 18.0,
        estimatedFareMax: 26.0,
      ),
    ];
    if (!mounted) return;
    final summary = route == null
        ? null
        : '${route.distanceText} · ${route.etaText}';
    final selection = await VehicleOptionsSheet.show(
      context,
      options: options,
      selectedId: _state.selectedVehicle?.id,
      routeSummary: summary,
    );
    if (selection == null || !mounted) {
      if (_state.phase == TripPlannerPhase.vehicleOptions) _state.goBack();
      return;
    }
    _state.selectVehicle(selection.vehicle);
    _state.setRidePreferences(
      passengerCount: selection.passengerCount,
      scheduledDeparture: selection.scheduledDeparture,
    );
    _presenceCategory = _databaseServiceType(selection.vehicle);
    final center = _currentLocation ?? _state.pickup?.point;
    if (center != null) _subscribeNearby(center);
    _state.proceedToPickupConfirmation();
  }

  Future<void> _openPickupConfirmationSheet() async {
    final pickup = _state.pickup;
    final destination = _state.destination;
    final vehicle = _state.selectedVehicle;
    final route = _state.route;
    if (pickup == null ||
        destination == null ||
        vehicle == null ||
        route == null) {
      return;
    }
    if (!mounted) return;
    final confirmation = await PickupConfirmationSheet.show(
      context,
      pickup: pickup,
      destination: destination,
      vehicle: vehicle,
      route: route,
      passengerCount: _state.passengerCount,
      scheduledDeparture: _state.scheduledDeparture,
    );
    if (!mounted) return;
    if (confirmation != null) {
      _state.setPickupNote(confirmation.pickupNote);
      final ok = await _state.submitRideRequest();
      if (ok) {
        _focusSelectedPlaces(pickup.point);
      } else if (mounted && _state.errorMessage != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_state.errorMessage!)));
      }
    } else if (_state.phase == TripPlannerPhase.pickupConfirmation) {
      _state.goBack();
    }
  }

  void _reviewTrip() {
    final pickup = _state.pickup;
    final destination = _state.destination;
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

  Future<void> _loadTransitStops() async {
    final center = _currentLocation ?? _state.pickup?.point;
    if (center == null) return;
    setState(() {
      _transitStatus = _TransitStatus.loading;
      _transitError = null;
    });
    try {
      final result = await _transitRepository.nearest(
        center,
        limit: 5,
        radiusMeters: 2000,
      );
      if (!mounted) return;
      setState(() {
        _nearbyStops = result;
        _transitStatus = result.isEmpty
            ? _TransitStatus.empty
            : _TransitStatus.data;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _transitStatus = _TransitStatus.error;
        _transitError = 'Unable to load stops: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final riderId = supabase.auth.currentUser?.id;
    final phase = _state.phase;
    final pickup = _state.pickup;
    final destination = _state.destination;
    final route = _state.route;
    final distance = pickup != null && destination != null
        ? straightLineDistanceMeters(pickup.point, destination.point)
        : null;

    List<LatLng> polylinePoints =
        _currentMatch?.bestRoute.points ??
        route?.points ??
        (pickup != null && destination != null
            ? [pickup.point, destination.point]
            : const []);
    final polylineColor = Theme.of(context).colorScheme.secondary;

    final markers = <Marker>[
      if (_currentLocation != null)
        Marker(
          point: _currentLocation!,
          width: 24,
          height: 24,
          child: const _CurrentLocationDot(),
        ),
    ];

    if (pickup != null && destination != null && _currentMatch != null) {
      final requests = _currentMatch!.requests;
      final me = RiderMarkerSet(
        riderIndex: 0,
        pickup: pickup.point,
        pickupPlace: pickup,
        destination: destination.point,
        destinationPlace: destination,
        isMe: true,
      );
      final partner = RiderMarkerSet(
        riderIndex: 1,
        pickup: requests[1].pickup,
        destination: requests[1].destination,
      );
      markers.addAll(
        SharedRouteMarkers.buildForRider(
          me: me,
          partner: partner,
          match: _currentMatch,
        ),
      );
    } else {
      if (pickup != null) {
        markers.add(
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
        );
      }
      if (destination != null) {
        markers.add(
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
        );
      }
    }

    for (final v in _nearby) {
      markers.add(
        Marker(
          point: v.coarseLocation,
          width: 32,
          height: 32,
          child: const _NearbyVehiclePin(),
        ),
      );
    }
    final exactDriverLocation = _state.assignedDriver?.exactLocation;
    if (exactDriverLocation != null) {
      markers.add(
        Marker(
          point: exactDriverLocation,
          width: 40,
          height: 40,
          child: const _NearbyVehiclePin(),
        ),
      );
    }
    if (_transitStatus == _TransitStatus.data) {
      for (final s in _nearbyStops) {
        markers.add(
          Marker(
            point: s.stop.location,
            width: 36,
            height: 36,
            alignment: Alignment.bottomCenter,
            child: _TransitStopPin(stop: s),
          ),
        );
      }
    }

    final showAssignedPanel =
        phase == TripPlannerPhase.searchingDriver ||
        phase == TripPlannerPhase.driverAssigned ||
        phase == TripPlannerPhase.enRoute;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Plan a ride'),
        actions: [
          IconButton(
            onPressed: _loadTransitStops,
            tooltip: 'Show nearby stops',
            icon: const Icon(Icons.directions_transit),
          ),
          if (phase.index >= TripPlannerPhase.routePreview.index &&
              phase.index < TripPlannerPhase.searchingDriver.index ||
              phase == TripPlannerPhase.completed ||
              phase == TripPlannerPhase.cancelled)
            IconButton(
              onPressed: () {
                _state.resetToExplore(keepPickup: _state.pickup);
              },
              tooltip: 'Start over',
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
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
                if (point != null) _moveTo(point);
                _loadTransitStops();
              },
              onTap: phase.index >= TripPlannerPhase.searchingDriver.index
                  ? null
                  : _selectPointOnMap,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.infrago.infra_go',
              ),
              if (polylinePoints.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: polylinePoints,
                      strokeWidth: 5,
                      color: polylineColor,
                      borderStrokeWidth: 2,
                      borderColor: Theme.of(context).colorScheme.surface,
                    ),
                  ],
                ),
              MarkerLayer(markers: markers),
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
          if (riderId != null && !showAssignedPanel)
            Positioned(
              left: AppSpacing.sm,
              right: AppSpacing.sm,
              top: 205,
              child: _ActiveRidePanel(riderId: riderId),
            ),
          Positioned(
            right: AppSpacing.gutter,
            bottom: showAssignedPanel ? 320 : 190,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'transitToggle',
                  onPressed: _loadTransitStops,
                  tooltip: 'Transit stops',
                  child: const Icon(Icons.directions_transit),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
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
              ],
            ),
          ),
          Positioned(
            left: AppSpacing.base,
            bottom: showAssignedPanel ? 310 : 176,
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
          if (_transitStatus != _TransitStatus.idle)
            Positioned(
              right: AppSpacing.gutter,
              top: 210,
              child: _TransitBadge(
                status: _transitStatus,
                count: _nearbyStops.length,
                error: _transitError,
                onRetry: _loadTransitStops,
              ),
            ),
          if (_nearby.isEmpty &&
              phase == TripPlannerPhase.routePreview &&
              _currentLocation != null)
            Positioned(
              left: AppSpacing.sm,
              bottom: showAssignedPanel ? 320 : 190,
              child: const _NoNearbyDriversBanner(),
            ),
          if (showAssignedPanel)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DriverAssignedPanel(
                driver:
                    _state.assignedDriver ??
                    const AssignedDriverInfo(
                      driverId: 'pending',
                      name: 'Looking for driver',
                      rating: 0,
                      vehicleMake: '-',
                      vehicleModel: '-',
                      vehiclePlate: '-',
                      vehicleColor: '-',
                      etaMinutes: 0,
                    ),
                phase: phase,
                cancelCountdownSeconds: _state.cancelCountdownSeconds,
                canCancelForFree: _state.canCancelForFree,
                onContactDriver: _state.assignedDriver != null
                    ? () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatWithDriverScreen(
                              rideId: _state.activeRideId,
                              title: 'Contact Driver',
                            ),
                          ),
                        );
                      }
                    : null,
                onCancelRide: _cancelActiveRide,
                onTrackDriver: _state.assignedDriver?.exactLocation == null
                    ? null
                    : () => _moveTo(_state.assignedDriver!.exactLocation!),
              ),
            )
          else
            Positioned(
              left: AppSpacing.sm,
              right: AppSpacing.sm,
              bottom: 30,
              child: _TripSummaryPanel(
                pickup: pickup,
                destination: destination,
                distanceMeters: distance,
                route: route,
                isLoadingRoute: _state.isLoadingRoute,
                isResolvingPin: _isResolvingPin,
                phase: phase,
                onChooseVehicle: pickup != null && destination != null
                    ? () {
                        const opt = VehicleOption(
                          id: 'economy_4',
                          name: 'Economy',
                          seats: 4,
                          estimatedFareMin: 8.0,
                          estimatedFareMax: 12.0,
                        );
                        _state.selectVehicle(opt);
                      }
                    : null,
                onReviewTrip: _reviewTrip,
              ),
            ),
        ],
      ),
    );
  }
}

class _NearbyVehiclePin extends StatelessWidget {
  const _NearbyVehiclePin();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Nearby available vehicle',
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
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
        child: Icon(Icons.local_taxi, color: Colors.white, size: 16),
      ),
    );
  }
}

class _TransitStopPin extends StatelessWidget {
  const _TransitStopPin({required this.stop});

  final NearbyTransitStop stop;

  @override
  Widget build(BuildContext context) {
    final stale = stop.stop.isStale;
    return Semantics(
      label: 'Transit stop ${stop.stop.name}',
      child: Tooltip(
        message:
            '${stop.stop.name} · ${stop.distanceLabel}${stale ? ' · Stale data' : ''}',
        child: Container(
          decoration: BoxDecoration(
            color: stale
                ? Theme.of(context).colorScheme.outlineVariant
                : const Color(0xFF1F477B),
            shape: BoxShape.rectangle,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Icon(Icons.directions_transit, color: Colors.white, size: 16),
        ),
      ),
    );
  }
}

class _TransitBadge extends StatelessWidget {
  const _TransitBadge({
    required this.status,
    required this.count,
    this.error,
    this.onRetry,
  });

  final _TransitStatus status;
  final int count;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: switch (status) {
          _TransitStatus.loading => const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: AppSpacing.base),
              Text('Loading stops…'),
            ],
          ),
          _TransitStatus.empty => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info_outline, size: 16),
              const SizedBox(width: AppSpacing.xs),
              const Text('No official stops within 2 km'),
              const SizedBox(width: AppSpacing.xs),
              IconButton(
                onPressed: onRetry,
                tooltip: 'Retry',
                icon: const Icon(Icons.refresh, size: 16),
              ),
            ],
          ),
          _TransitStatus.error => Tooltip(
            message: error,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error,
                  size: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  'Stops unavailable',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(width: AppSpacing.xs),
                IconButton(
                  onPressed: onRetry,
                  tooltip: 'Retry',
                  icon: const Icon(Icons.refresh, size: 16),
                ),
              ],
            ),
          ),
          _TransitStatus.data => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.directions_transit, size: 16),
              const SizedBox(width: AppSpacing.xs),
              Text('$count nearby stops'),
            ],
          ),
          _ => const SizedBox.shrink(),
        },
      ),
    );
  }
}

class _NoNearbyDriversBanner extends StatelessWidget {
  const _NoNearbyDriversBanner();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: const Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline, size: 16),
            SizedBox(width: AppSpacing.base),
            Flexible(child: Text('No nearby drivers at the moment.')),
          ],
        ),
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
      if (!mounted || requestNumber != _requestNumber) return;
      setState(() => _results = results);
    } on LocationSearchException catch (error) {
      if (!mounted || requestNumber != _requestNumber) return;
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
                if (value.trim().length >= 3) _search(value.trim());
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
    required this.route,
    required this.isLoadingRoute,
    required this.isResolvingPin,
    required this.phase,
    required this.onChooseVehicle,
    required this.onReviewTrip,
  });

  final GeoPlace? pickup;
  final GeoPlace? destination;
  final double? distanceMeters;
  final TripPlanRoute? route;
  final bool isLoadingRoute;
  final bool isResolvingPin;
  final TripPlannerPhase phase;
  final VoidCallback? onChooseVehicle;
  final VoidCallback onReviewTrip;

  @override
  Widget build(BuildContext context) {
    final canContinue = pickup != null && destination != null;
    final title = switch (phase) {
      TripPlannerPhase.explore =>
        pickup != null && destination != null
            ? 'Route preview ready'
            : 'Choose a destination',
      TripPlannerPhase.routePreview => 'Review & choose vehicle',
      TripPlannerPhase.vehicleOptions => 'Vehicle options',
      TripPlannerPhase.pickupConfirmation => 'Confirming pickup',
      _ => 'Trip in progress',
    };
    String sub;
    if (isLoadingRoute) {
      sub = 'Computing route…';
    } else if (isResolvingPin) {
      sub = 'Finding address…';
    } else if (route != null) {
      sub = '${route!.distanceText} · ETA ${route!.etaText} (real road)';
    } else if (distanceMeters == null) {
      sub = 'Search above or tap the map to place a pin.';
    } else {
      sub =
          '${(distanceMeters! / 1000).toStringAsFixed(2)} km straight-line preview';
    }
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
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.xs),
                  Text(sub, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            phase == TripPlannerPhase.routePreview
                ? ElevatedButton.icon(
                    onPressed: onChooseVehicle,
                    icon: const Icon(Icons.local_taxi, size: 18),
                    label: const Text('Choose'),
                  )
                : ElevatedButton(
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
        if (snapshot.hasError) return const SizedBox.shrink();
        final rides = (snapshot.data ?? [])
            .map(Ride.fromJson)
            .where(
              (ride) =>
                  ride.status != 'completed' && ride.status != 'cancelled',
            )
            .toList();
        if (rides.isEmpty) return const SizedBox.shrink();
        final activeRide = rides.last;
        final canChat =
            activeRide.driverId != null &&
            (activeRide.status == 'driver_assigned' ||
                activeRide.status == 'en_route');
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
