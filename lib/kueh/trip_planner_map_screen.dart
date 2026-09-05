import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/kueh/carpool_matcher.dart';
import 'package:infra_go/kueh/chat_with_driver_screen.dart';
import 'package:infra_go/foo/cancellation_policy.dart';
import 'package:infra_go/foo/checkout_sheet.dart';
import 'package:infra_go/kueh/driver_assigned_panel.dart';
import 'package:infra_go/foo/fare_estimator.dart';
import 'package:infra_go/foo/landmark_photo_sheet.dart';
import 'package:infra_go/kueh/location_search_service.dart';
import 'package:infra_go/kueh/osrm_routing_service.dart';
import 'package:infra_go/foo/payment_method.dart';
import 'package:infra_go/foo/payment_repository.dart';
import 'package:infra_go/kueh/pickup_confirmation_sheet.dart';
import 'package:infra_go/foo/pickup_landmark_service.dart';
import 'package:infra_go/foo/receipt_screen.dart';
import 'package:infra_go/foo/ride_booking_repository.dart';
import 'package:infra_go/tey/rewards_repository.dart';
import 'package:infra_go/kueh/shared_route_markers.dart';
import 'package:infra_go/kueh/supabase_carpool_service.dart';
import 'package:infra_go/shared/supabase_config.dart';
import 'package:infra_go/tey/transit_stop_repository.dart';
import 'package:infra_go/kueh/trip_planner_repository.dart';
import 'package:infra_go/kueh/trip_planner_state.dart';
import 'package:infra_go/kueh/vehicle_options_sheet.dart';
import 'package:infra_go/kueh/vehicle_presence_service.dart';
import 'package:infra_go/weather/route_weather_service.dart';

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

bool hasDriverReachedPickup(LatLng driver, LatLng pickup) =>
    haversineMeters(driver, pickup) <= 100;

LatLng? assignedDriverEtaTarget({
  required TripPlannerPhase phase,
  required LatLng? pickup,
  required LatLng? destination,
}) => switch (phase) {
  TripPlannerPhase.driverAssigned => pickup,
  TripPlannerPhase.enRoute => destination,
  _ => null,
};

enum _MapEditTarget { pickup, destination }

enum _TransitStatus { idle, loading, data, empty, error }

class TripPlannerMapScreen extends StatefulWidget {
  const TripPlannerMapScreen({
    super.key,
    this.initialPickup,
    this.initialDestination,
  });

  final GeoPlace? initialPickup;
  final GeoPlace? initialDestination;

  @override
  State<TripPlannerMapScreen> createState() => _TripPlannerMapScreenState();
}

class _TripPlannerMapScreenState extends State<TripPlannerMapScreen> {
  final MapController _mapController = MapController();
  final Set<String> _handledCompletedRideIds = <String>{};
  final PhotonLocationSearchService _locationSearch =
      PhotonLocationSearchService();
  final OsrmRoutingService _routing = OsrmRoutingService();
  late final TripPlannerState _state;
  late final VehiclePresenceService _presence;

  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<List<CoarseVehicle>>? _nearbySubscription;
  StreamSubscription<RideLifecycleSnapshot>? _assignedSubscription;
  StreamSubscription<ExactDriver?>? _exactDriverSubscription;
  Timer? _driverEtaRefreshTimer;
  ExactDriver? _latestExactDriver;
  bool _driverEtaRefreshInFlight = false;

  LatLng? _currentLocation;
  String? _locationMessage;
  bool _isLocating = true;
  bool _isResolvingPin = false;
  bool _mapIsReady = false;
  _MapEditTarget _mapEditTarget = _MapEditTarget.destination;

  List<CoarseVehicle> _nearby = const [];
  _TransitStatus _transitStatus = _TransitStatus.idle;
  List<NearbyTransitStop> _nearbyStops = const [];
  NearbyTransitStop? _selectedTransitStop;
  String? _transitError;
  CarpoolMatch? _currentMatch;
  late final TripPlannerRepository _tripRepository;
  late final SupabaseCarpoolService _carpoolService;
  late final TransitStopRepository _transitRepository;
  late final RideBookingRepository _rideBookingRepository;
  late final PaymentRepository _paymentRepository;
  late final RewardsRepository _rewardsRepository;
  late final PickupLandmarkService _landmarkService;
  late final RouteWeatherService _weatherService;
  RouteWeatherAdvisory? _weatherAdvisory;
  String _presenceCategory = 'economy_4';
  PaymentMethod? _selectedPaymentMethod;
  int _selectedRewardPoints = 0;
  PickedLandmarkPhoto? _pendingLandmarkPhoto;
  bool _isPickupConfirmationFlowActive = false;

  @override
  void initState() {
    super.initState();
    _state = TripPlannerState(routing: _routing, search: _locationSearch);
    _state.addListener(_onStateChanged);
    _state.onRequestSubmitted(_handleRequestSubmitted);
    _state.onCancelRequested(_handleCancelled);
    if (widget.initialPickup != null) _state.setPickup(widget.initialPickup!);
    if (widget.initialDestination != null) {
      _state.setDestination(widget.initialDestination!);
    }
    _tripRepository = SupabaseTripPlannerRepository(supabase);
    _rideBookingRepository = RideBookingRepository(supabase);
    _paymentRepository = PaymentRepository(supabase);
    _landmarkService = PickupLandmarkService();
    _weatherService = RouteWeatherService();
    _rewardsRepository = RewardsRepository(supabase);
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

  String? _lastShimmerError;

  void _onStateChanged() {
    if (!mounted) return;
    final phase = _state.phase;
    setState(() {
      if (phase == TripPlannerPhase.explore ||
          phase == TripPlannerPhase.cancelled) {
        _currentMatch = null;
      }
    });
    final errorMessage = _state.errorMessage;
    if (errorMessage != null && errorMessage != _lastShimmerError) {
      _lastShimmerError = errorMessage;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (errorMessage == null) {
      _lastShimmerError = null;
    }
    if (phase == TripPlannerPhase.vehicleOptions &&
        _state.selectedVehicle == null) {
      unawaited(_openVehicleOptionsSheet());
    }
    if (phase == TripPlannerPhase.pickupConfirmation &&
        !_isPickupConfirmationFlowActive) {
      unawaited(_openPickupConfirmationSheet());
    }
  }

  String _generateClientRequestId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(4294967296)}';

  Future<void> _handleRequestSubmitted() async {
    final pickup = _state.pickup;
    final destination = _state.destination;
    final vehicle = _state.selectedVehicle;
    final route = _state.route;
    final userId = supabase.auth.currentUser?.id;
    final paymentMethod = _selectedPaymentMethod;
    final transitStop = vehicle?.isShared == true ? _selectedTransitStop : null;
    if (pickup == null ||
        destination == null ||
        vehicle == null ||
        route == null ||
        userId == null ||
        paymentMethod == null) {
      throw const TripPlannerRepositoryException(
        'Sign in and complete the trip and checkout before requesting a ride.',
      );
    }
    final landmarkPhoto = _pendingLandmarkPhoto;
    try {
      final result = await _rideBookingRepository.createRideWithQuoteAndPayment(
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
        transitStopId: transitStop?.stop.id,
        transitStopName: transitStop?.stop.name,
        paymentMethod: paymentMethod,
        clientRequestId: _generateClientRequestId(),
        rewardPointsToRedeem: _selectedRewardPoints,
      );
      if (landmarkPhoto != null) {
        await _uploadLandmarkPhoto(userId, result.rideId, landmarkPhoto);
      }
      _state.setActiveRideId(result.rideId);
      _watchRide(result.rideId);
      if (vehicle.isShared) unawaited(_trySharedMatch(result.rideId));
    } on RideBookingException catch (error) {
      throw TripPlannerRepositoryException('Booking failed: $error');
    } finally {
      _selectedPaymentMethod = null;
      _selectedRewardPoints = 0;
      _pendingLandmarkPhoto = null;
    }
  }

  Future<void> _uploadLandmarkPhoto(
    String riderId,
    String rideId,
    PickedLandmarkPhoto photo,
  ) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Uploading pickup photo…'),
        duration: Duration(seconds: 30),
      ),
    );
    try {
      await _landmarkService.upload(
        riderId: riderId,
        rideId: rideId,
        photo: photo,
      );
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
    } catch (error) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Pickup photo upload failed.'),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () =>
                unawaited(_uploadLandmarkPhoto(riderId, rideId, photo)),
          ),
        ),
      );
    }
  }

  List<VehicleOption> _vehicleOptionsForRoute(TripPlanRoute? route) {
    FareQuote? quoteFor(FareServiceType type) => route == null
        ? null
        : FareEstimator.quote(
            serviceType: type,
            distanceMeters: route.distanceMeters,
            durationSeconds: route.durationSeconds,
          );

    final economy = quoteFor(FareServiceType.economy4);
    final shared = quoteFor(FareServiceType.sharedEconomy);
    final sixSeater = quoteFor(FareServiceType.sixSeater);

    return [
      VehicleOption(
        id: 'economy_4',
        name: 'Economy',
        seats: 4,
        estimatedFareMin: economy?.amount,
        estimatedFareMax: economy?.amount,
      ),
      VehicleOption(
        id: 'shared_economy',
        name: 'Shared Economy',
        seats: 4,
        isShared: true,
        estimatedFareMin: shared?.amount,
        estimatedFareMax: shared?.amount,
      ),
      VehicleOption(
        id: 'six_seater',
        name: 'SUV / 6-seater',
        seats: 6,
        estimatedFareMin: sixSeater?.amount,
        estimatedFareMax: sixSeater?.amount,
      ),
    ];
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
    _driverEtaRefreshTimer?.cancel();
    _latestExactDriver = null;
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
                if (!_handledCompletedRideIds.add(rideId)) return;
                _state.markCompleted();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ReceiptScreen(rideId: rideId),
                  ),
                );
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
      _driverEtaRefreshTimer?.cancel();
      _exactDriverSubscription = _presence.exactAssigned(rideId: rideId).listen(
        (exact) {
          final current = _state.assignedDriver;
          if (!mounted || exact == null || current == null) return;
          final pickup = _state.pickup?.point;
          _latestExactDriver = exact;
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
              remainingDistanceMeters: current.remainingDistanceMeters,
              tripProgress: current.tripProgress,
              isAtPickup:
                  pickup != null &&
                  hasDriverReachedPickup(exact.exactLocation, pickup),
            ),
          );
          unawaited(_refreshAssignedDriverEta(exact));
        },
      );
      _driverEtaRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        final exact = _latestExactDriver;
        if (exact != null) unawaited(_refreshAssignedDriverEta(exact));
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Driver details unavailable: $error')),
      );
    }
  }

  Future<void> _refreshAssignedDriverEta(ExactDriver exact) async {
    if (_driverEtaRefreshInFlight || !mounted) return;
    final target = assignedDriverEtaTarget(
      phase: _state.phase,
      pickup: _state.pickup?.point,
      destination: _state.destination?.point,
    );
    if (target == null) return;
    _driverEtaRefreshInFlight = true;
    try {
      final result = await _routing.route(
        exact.exactLocation,
        target,
        useCache: false,
      );
      final current = _state.assignedDriver;
      if (!mounted || current == null || current.driverId != exact.driverId) {
        return;
      }
      final isEnRoute = _state.phase == TripPlannerPhase.enRoute;
      final totalDistance = _state.route?.distanceMeters;
      final progress = isEnRoute && totalDistance != null && totalDistance > 0
          ? (1 - result.distanceMeters / totalDistance).clamp(0.0, 1.0)
          : null;
      _state.markDriverAssigned(
        AssignedDriverInfo(
          driverId: current.driverId,
          name: current.name,
          rating: current.rating,
          vehicleMake: current.vehicleMake,
          vehicleModel: current.vehicleModel,
          vehiclePlate: exact.vehiclePlate,
          vehicleColor: current.vehicleColor,
          etaMinutes: (result.durationSeconds / 60).ceil(),
          exactLocation: exact.exactLocation,
          phoneLastFour: current.phoneLastFour,
          remainingDistanceMeters: result.distanceMeters,
          tripProgress: progress,
          isAtPickup: current.isAtPickup,
        ),
      );
    } catch (_) {
      // Keep the most recent valid ETA when OSRM is temporarily unavailable.
    } finally {
      _driverEtaRefreshInFlight = false;
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
      nearestTransitStopId: _selectedTransitStop?.stop.id,
    );
    try {
      final matches = await _carpoolService.findMatches(request);
      if (!mounted || _state.activeRideId != rideId) return;
      if (matches.isEmpty) {
        await _offerSharedNoMatchChoice(rideId);
        return;
      }
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
      final groupId = await _carpoolService.commitMatch(match);
      if (!mounted) return;
      _state.markSharedMatched(groupId);
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

  Future<void> _offerSharedNoMatchChoice(String rideId) async {
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('No shared match yet'),
        content: const Text(
          'No other rider matched this trip yet. Continue alone at the '
          'solo Economy fare, or cancel for free while still searching.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'wait'),
            child: const Text('Keep waiting'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel ride'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'solo'),
            child: const Text('Continue solo'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null || choice == 'wait') return;
    if (choice == 'cancel') {
      await _cancelActiveRide();
      return;
    }
    await _continueSharedRideSolo(rideId);
  }

  Future<void> _continueSharedRideSolo(String rideId) async {
    try {
      final result = await _paymentRepository.convertSharedRideToSolo(rideId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Continuing solo at the Economy fare · '
            'RM${(result['amount'] as num).toStringAsFixed(2)}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final databaseFunctionMissing =
          error.toString().contains('PGRST202') ||
          error.toString().contains('continue_shared_ride_solo');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            databaseFunctionMissing
                ? 'Solo conversion is not installed on the server yet. '
                      'Your shared request is unchanged and still waiting.'
                : 'Could not switch to solo. Your shared request was not changed.',
          ),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => unawaited(_continueSharedRideSolo(rideId)),
          ),
        ),
      );
    }
  }

  Future<void> _cancelActiveRide() async {
    final rideId = _state.activeRideId;
    if (rideId == null) return;

    final Map<String, dynamic> rideRow;
    try {
      rideRow = await supabase
          .from('rides')
          .select('status, accepted_at, departure_time')
          .eq('id', rideId)
          .single();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load ride details: $error')),
      );
      return;
    }

    final Map<String, dynamic>? paymentRow = await supabase
        .from('payments')
        .select('quoted_amount, discount_amount')
        .eq('ride_id', rideId)
        .inFilter('status', ['pending', 'authorised', 'paid'])
        .maybeSingle();
    if (paymentRow == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Could not find this ride's payment details."),
        ),
      );
      return;
    }

    final confirmedFare =
        (paymentRow['quoted_amount'] as num).toDouble() -
        (paymentRow['discount_amount'] as num).toDouble();
    final acceptedAt = rideRow['accepted_at'] == null
        ? null
        : DateTime.parse(rideRow['accepted_at'] as String);
    final departureTime = DateTime.parse(rideRow['departure_time'] as String);
    final now = DateTime.now();
    final assignedDriver = _state.assignedDriver;
    final driverLateMinutes = acceptedAt == null || assignedDriver == null
        ? null
        : now.difference(acceptedAt).inMinutes - assignedDriver.etaMinutes;

    final outcome = CancellationPolicy.evaluate(
      cancelledBy: CancelledBy.rider,
      rideStatus: rideRow['status'] as String,
      confirmedFare: confirmedFare,
      now: now,
      acceptedAt: acceptedAt,
      isScheduled: _state.scheduledDeparture != null,
      departureTime: departureTime,
      driverLateMinutes: driverLateMinutes,
    );

    if (!outcome.cancellable) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This ride can no longer be cancelled here.'),
        ),
      );
      return;
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel this ride?'),
        content: Text(
          outcome.isFree
              ? 'This cancellation is free.'
              : 'A cancellation fee of RM${outcome.fee.toStringAsFixed(2)} applies.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep ride'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel ride'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _paymentRepository.cancelRideAndSettlePayment(
        rideId: rideId,
        cancelledBy: 'rider',
        reason: 'Rider cancelled',
        policyVersion: CancellationPolicy.policyVersion,
        fee: outcome.fee,
      );
      if (!mounted) return;
      _state.cancelCurrentFlow(reason: 'Rider cancelled');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            outcome.isFree
                ? 'Ride cancelled for free.'
                : 'Ride cancelled. Fee: RM${outcome.fee.toStringAsFixed(2)}',
          ),
        ),
      );
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
    _driverEtaRefreshTimer?.cancel();
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
    final inRegion = isInsidePeninsularMalaysia(point);
    setState(() {
      _currentLocation = inRegion ? point : null;
      _isLocating = false;
      _locationMessage = inRegion
          ? null
          : 'Your current location is outside $kPeninsularMyAreaLabel. '
                'Select a point on the map instead.';
    });
    if (inRegion) {
      final shouldSetPickup = _state.pickup == null;
      if (shouldSetPickup) {
        final place = GeoPlace.coordinate(point, name: 'Current location');
        _state.setPickup(place);
        unawaited(_resolvePin(point, _MapEditTarget.pickup));
      }
      if (moveMap) _moveTo(point);
      _subscribeNearby(point);
    }
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
    if (!isInsidePeninsularMalaysia(point)) {
      _showRegionSnackBar();
      return;
    }
    final place = GeoPlace.coordinate(point, name: 'Current location');
    _clearTransitSelection();
    _state.setPickup(place);
    setState(() => _mapEditTarget = _MapEditTarget.destination);
    _moveTo(point);
    await _resolvePin(point, _MapEditTarget.pickup);
  }

  void _selectPointOnMap(TapPosition _, LatLng point) {
    if (!isInsidePeninsularMalaysia(point)) {
      _showRegionSnackBar();
      return;
    }
    final target = _mapEditTarget;
    final place = GeoPlace.coordinate(point);
    if (target == _MapEditTarget.pickup) {
      _clearTransitSelection();
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
      // A failed reverse lookup keeps the tapped coordinates as-is; the
      // caller's finally block already clears the resolving flag.
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
    if (!isInsidePeninsularMalaysia(place.point)) {
      _showRegionSnackBar();
      return;
    }
    if (target == _MapEditTarget.pickup) {
      _clearTransitSelection();
      _state.setPickup(place);
      setState(() => _mapEditTarget = _MapEditTarget.destination);
    } else {
      _state.setDestination(place);
      setState(() => _mapEditTarget = _MapEditTarget.destination);
    }
    _focusSelectedPlaces(place.point);
  }

  void _showRegionSnackBar() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(kErrorOutsideMyRegion),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _refreshWeatherAdvisory() async {
    final pickup = _state.pickup;
    final destination = _state.destination;
    if (pickup == null || destination == null) return;
    try {
      _weatherAdvisory = await _weatherService.fetchRouteAdvisory(
        pickup: pickup.point,
        destination: destination.point,
        pickupLabel: pickup.name,
        destinationLabel: destination.name,
      );
    } catch (_) {
      // Weather is an optional, non-blocking hint — a failed fetch just
      // means the pickup-confirmation banner stays hidden.
      _weatherAdvisory = null;
    }
  }

  Future<void> _openVehicleOptionsSheet() async {
    final route = _state.route;
    if (route == null) {
      if (mounted && _state.errorMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_state.errorMessage!),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      if (_state.phase == TripPlannerPhase.vehicleOptions) _state.goBack();
      return;
    }
    if (route.distanceMeters > kMaximumRideDistanceMeters) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(kErrorRideTooFar(route.distanceMeters)),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      if (_state.phase == TripPlannerPhase.vehicleOptions) _state.goBack();
      return;
    }
    final options = _vehicleOptionsForRoute(route);
    if (!mounted) return;
    // Kicked off here (not awaited) so it has the time the user spends
    // picking a vehicle to resolve before reaching pickup confirmation.
    unawaited(_refreshWeatherAdvisory());
    final summary = '${route.distanceText} · ${route.etaText}';
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
    _isPickupConfirmationFlowActive = true;
    try {
      final confirmation = await PickupConfirmationSheet.show(
        context,
        pickup: pickup,
        destination: destination,
        vehicle: vehicle,
        route: route,
        passengerCount: _state.passengerCount,
        scheduledDeparture: _state.scheduledDeparture,
        transitStopName: vehicle.isShared
            ? _selectedTransitStop?.stop.name
            : null,
        weatherAdvisory: _weatherAdvisory,
      );
      if (!mounted) return;
      if (confirmation == null) {
        if (_state.phase == TripPlannerPhase.pickupConfirmation) {
          _state.goBack();
        }
        return;
      }
      _state.setPickupNote(confirmation.pickupNote);

      if (!mounted) return;
      _pendingLandmarkPhoto = await LandmarkPhotoSheet.show(
        context,
        service: _landmarkService,
      );

      final quote = FareEstimator.quote(
        serviceType: FareServiceType.fromDbValue(_databaseServiceType(vehicle)),
        distanceMeters: route.distanceMeters,
        durationSeconds: route.durationSeconds,
      );
      if (!mounted) return;
      final selection = await CheckoutSheet.show(
        context,
        amount: quote.amount,
        currency: quote.currency,
        paymentRepository: _paymentRepository,
        rewardsRepository: _rewardsRepository,
      );
      if (!mounted) return;
      if (selection == null) {
        if (_state.phase == TripPlannerPhase.pickupConfirmation) {
          _state.goBack();
        }
        return;
      }
      _selectedPaymentMethod = selection.method;
      _selectedRewardPoints = selection.rewardPointsToRedeem;

      final ok = await _state.submitRideRequest();
      if (ok) {
        _focusSelectedPlaces(pickup.point);
      } else if (mounted && _state.errorMessage != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_state.errorMessage!)));
      }
    } finally {
      _isPickupConfirmationFlowActive = false;
    }
  }

  Future<void> _loadTransitStops() async {
    final center = _state.pickup?.point ?? _currentLocation;
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
        final selectedId = _selectedTransitStop?.stop.id;
        if (selectedId != null &&
            !result.any((item) => item.stop.id == selectedId)) {
          _selectedTransitStop = null;
        }
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

  void _clearTransitSelection() {
    if (_selectedTransitStop == null || !mounted) return;
    setState(() => _selectedTransitStop = null);
  }

  void _resetPlanner() {
    _driverEtaRefreshTimer?.cancel();
    _latestExactDriver = null;
    _clearTransitSelection();
    _state.resetToExplore(keepPickup: _state.pickup);
  }

  Future<void> _openTransitStopDetails(NearbyTransitStop stop) async {
    if (_state.phase.index >= TripPlannerPhase.searchingDriver.index) return;
    final alreadySelected = _selectedTransitStop?.stop.id == stop.stop.id;
    final updated = stop.stop.lastUpdated?.toLocal();
    final updatedLabel = updated == null
        ? 'Update time unavailable'
        : '${updated.year}-${updated.month.toString().padLeft(2, '0')}-'
              '${updated.day.toString().padLeft(2, '0')} '
              '${updated.hour.toString().padLeft(2, '0')}:'
              '${updated.minute.toString().padLeft(2, '0')}';
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(stop.stop.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text('${stop.distanceLabel} from pickup'),
            if (stop.stop.route != null) Text('Route: ${stop.stop.route}'),
            const SizedBox(height: AppSpacing.md),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dataset_outlined),
              title: Text(stop.stop.source ?? 'Official GTFS stop data'),
              subtitle: Text(
                '$updatedLabel${stop.stop.isStale ? ' · data may be stale' : ''}',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton.icon(
              onPressed: () =>
                  Navigator.pop(context, alreadySelected ? 'remove' : 'select'),
              icon: Icon(alreadySelected ? Icons.close : Icons.add_road),
              label: Text(
                alreadySelected
                    ? 'Remove transit connection'
                    : 'Use as Shared Ride connection',
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    setState(() => _selectedTransitStop = action == 'select' ? stop : null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          action == 'remove'
              ? 'Transit connection removed.'
              : '${stop.stop.name} selected for a Shared Economy connection.',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
            child: _TransitStopPin(
              stop: s,
              selected: _selectedTransitStop?.stop.id == s.stop.id,
              onTap: () => unawaited(_openTransitStopDetails(s)),
            ),
          ),
        );
      }
    }

    final showAssignedPanel =
        phase == TripPlannerPhase.searchingDriver ||
        phase == TripPlannerPhase.driverAssigned ||
        phase == TripPlannerPhase.enRoute;
    final safeTop = MediaQuery.paddingOf(context).top;
    final showReset =
        destination != null ||
        phase == TripPlannerPhase.completed ||
        phase == TripPlannerPhase.cancelled;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
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
          if (!showAssignedPanel)
            Positioned(
              left: AppSpacing.base,
              right: AppSpacing.base,
              top: safeTop + AppSpacing.base,
              child: _RideSearchCard(
                pickup: pickup,
                destination: destination,
                isLocating: _isLocating,
                locationMessage: _locationMessage,
                mapEditTarget: _mapEditTarget,
                showReset: showReset,
                onReset: _resetPlanner,
                onSearchPickup: () => _openPlaceSearch(_MapEditTarget.pickup),
                onSearchDestination: () =>
                    _openPlaceSearch(_MapEditTarget.destination),
                onUseCurrentLocation: _useCurrentLocation,
                onMapEditTargetChanged: (target) {
                  setState(() => _mapEditTarget = target);
                },
              ),
            ),
          Positioned(
            right: AppSpacing.base,
            top: showAssignedPanel ? safeTop + AppSpacing.base : safeTop + 224,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MapControlButton(
                  key: const Key('map_control_transit'),
                  icon: Icons.directions_transit,
                  onPressed: _loadTransitStops,
                  tooltip: 'Nearby public transport stops (GTFS)',
                  selected: _selectedTransitStop != null,
                  loading: _transitStatus == _TransitStatus.loading,
                ),
                const SizedBox(height: 2),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    boxShadow: const [
                      BoxShadow(color: Colors.black12, blurRadius: 4),
                    ],
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: 2,
                    ),
                    child: Text('Transit', style: TextStyle(fontSize: 10)),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                _MapControlButton(
                  key: const Key('map_control_location'),
                  icon: _currentLocation == null
                      ? Icons.location_searching
                      : Icons.my_location,
                  onPressed: _currentLocation == null
                      ? _startLocationTracking
                      : () => _moveTo(_currentLocation!),
                  tooltip: _currentLocation == null
                      ? 'Retry location'
                      : 'Centre on my location',
                ),
              ],
            ),
          ),
          Positioned(
            left: AppSpacing.base,
            bottom: phase == TripPlannerPhase.enRoute
                ? 430
                : showAssignedPanel
                ? 360
                : 198,
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
                sharedMatchFound: _state.isSharedMatchedWaitingDriver,
                destinationName: _state.destination?.name,
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
              left: 0,
              right: 0,
              bottom: 0,
              child: _TripSummaryPanel(
                key: const Key('bolt_trip_panel'),
                pickup: pickup,
                destination: destination,
                distanceMeters: distance,
                route: route,
                isLoadingRoute: _state.isLoadingRoute,
                isResolvingPin: _isResolvingPin,
                phase: phase,
                nearbyDriverCount: _nearby.length,
                transitStatus: _transitStatus,
                transitStopCount: _nearbyStops.length,
                transitError: _transitError,
                selectedTransitName: _selectedTransitStop?.stop.name,
                onChooseVehicle: route != null
                    ? () => unawaited(_openVehicleOptionsSheet())
                    : null,
                onSearchDestination: () =>
                    _openPlaceSearch(_MapEditTarget.destination),
                onReset: _resetPlanner,
                onTransitTap: _loadTransitStops,
              ),
            ),
        ],
      ),
    );
  }
}

class _MapControlButton extends StatelessWidget {
  const _MapControlButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.selected = false,
    this.loading = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final bool selected;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      elevation: 4,
      color: selected ? colors.primary : colors.surface,
      shape: const CircleBorder(),
      child: IconButton(
        onPressed: loading ? null : onPressed,
        tooltip: tooltip,
        icon: loading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: selected ? colors.onPrimary : colors.primary,
                ),
              )
            : Icon(icon, color: selected ? colors.onPrimary : colors.onSurface),
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
  const _TransitStopPin({
    required this.stop,
    required this.selected,
    required this.onTap,
  });

  final NearbyTransitStop stop;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final stale = stop.stop.isStale;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Transit stop ${stop.stop.name}${selected ? ', selected' : ''}',
      child: Tooltip(
        message:
            '${stop.stop.name} · ${stop.distanceLabel}${stale ? ' · Stale data' : ''}',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.tertiary
                  : stale
                  ? Theme.of(context).colorScheme.outlineVariant
                  : const Color(0xFF1F477B),
              shape: BoxShape.rectangle,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.onTertiary
                    : Colors.white,
                width: selected ? 3 : 2,
              ),
            ),
            child: Icon(
              selected ? Icons.check : Icons.directions_transit,
              color: Colors.white,
              size: 16,
            ),
          ),
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
    required this.showReset,
    required this.onReset,
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
  final bool showReset;
  final VoidCallback onReset;
  final VoidCallback onSearchPickup;
  final VoidCallback onSearchDestination;
  final VoidCallback onUseCurrentLocation;
  final ValueChanged<_MapEditTarget> onMapEditTargetChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const Key('bolt_search_panel'),
      elevation: 8,
      color: colors.surface,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.local_taxi_rounded,
                    color: colors.onPrimary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Where are you going?',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (showReset)
                  IconButton(
                    onPressed: onReset,
                    tooltip: 'Clear trip',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
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
            const SizedBox(height: 6),
            _LocationSearchField(
              icon: Icons.location_pin,
              iconColor: Theme.of(context).colorScheme.error,
              label: 'Destination',
              value: destination?.bookingLabel ?? 'Where are you going?',
              onTap: onSearchDestination,
            ),
            if (locationMessage != null) ...[
              const SizedBox(height: AppSpacing.xs),
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
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                Text(
                  'Move pin on map',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const Spacer(),
                ChoiceChip(
                  label: const Text('Pickup'),
                  selected: mapEditTarget == _MapEditTarget.pickup,
                  visualDensity: VisualDensity.compact,
                  showCheckmark: false,
                  onSelected: (_) =>
                      onMapEditTargetChanged(_MapEditTarget.pickup),
                ),
                const SizedBox(width: AppSpacing.xs),
                ChoiceChip(
                  label: const Text('Drop-off'),
                  selected: mapEditTarget == _MapEditTarget.destination,
                  visualDensity: VisualDensity.compact,
                  showCheckmark: false,
                  onSelected: (_) =>
                      onMapEditTargetChanged(_MapEditTarget.destination),
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
    super.key,
    required this.pickup,
    required this.destination,
    required this.distanceMeters,
    required this.route,
    required this.isLoadingRoute,
    required this.isResolvingPin,
    required this.phase,
    required this.nearbyDriverCount,
    required this.transitStatus,
    required this.transitStopCount,
    required this.transitError,
    required this.selectedTransitName,
    required this.onChooseVehicle,
    required this.onSearchDestination,
    required this.onReset,
    required this.onTransitTap,
  });

  final GeoPlace? pickup;
  final GeoPlace? destination;
  final double? distanceMeters;
  final TripPlanRoute? route;
  final bool isLoadingRoute;
  final bool isResolvingPin;
  final TripPlannerPhase phase;
  final int nearbyDriverCount;
  final _TransitStatus transitStatus;
  final int transitStopCount;
  final String? transitError;
  final String? selectedTransitName;
  final VoidCallback? onChooseVehicle;
  final VoidCallback onSearchDestination;
  final VoidCallback onReset;
  final VoidCallback onTransitTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tripEnded =
        phase == TripPlannerPhase.completed ||
        phase == TripPlannerPhase.cancelled;
    final title = switch (phase) {
      TripPlannerPhase.routePreview => 'Choose how you want to ride',
      TripPlannerPhase.vehicleOptions => 'Select your ride',
      TripPlannerPhase.pickupConfirmation => 'Confirm your pickup',
      TripPlannerPhase.completed => 'You have arrived',
      TripPlannerPhase.cancelled => 'Ride cancelled',
      _ => destination == null ? 'Search your destination' : 'Building route',
    };
    String subtitle;
    if (isLoadingRoute) {
      subtitle = 'Calculating the best road route…';
    } else if (isResolvingPin) {
      subtitle = 'Finding this address…';
    } else if (route != null) {
      subtitle = '${route!.distanceText} · About ${route!.etaText}';
    } else if (distanceMeters == null) {
      subtitle = 'Enter a place above or move the pin on the map.';
    } else {
      subtitle =
          '${(distanceMeters! / 1000).toStringAsFixed(1)} km direct distance';
    }

    final transitLabel = selectedTransitName != null
        ? selectedTransitName!
        : switch (transitStatus) {
            _TransitStatus.loading => 'Loading stops',
            _TransitStatus.data => '$transitStopCount transit stops',
            _TransitStatus.empty => 'No stops nearby',
            _TransitStatus.error => 'Transit unavailable',
            _ => 'Transit connection',
          };
    final primaryLabel = tripEnded
        ? 'Plan another ride'
        : route != null
        ? 'Choose a ride'
        : destination == null
        ? 'Search destination'
        : 'Calculating route…';
    final primaryAction = tripEnded
        ? onReset
        : route != null
        ? onChooseVehicle
        : destination == null
        ? onSearchDestination
        : null;

    return SafeArea(
      top: false,
      child: Material(
        color: colors.surface,
        elevation: 14,
        shadowColor: Colors.black26,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.outlineVariant,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
              if (isLoadingRoute) ...[
                const SizedBox(height: AppSpacing.sm),
                const LinearProgressIndicator(minHeight: 3),
              ],
              const SizedBox(height: AppSpacing.sm),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _InfoPill(
                      icon: Icons.local_taxi_outlined,
                      label: nearbyDriverCount == 0
                          ? 'No cars nearby'
                          : '$nearbyDriverCount cars nearby',
                    ),
                    if (!(transitStatus == _TransitStatus.empty &&
                        selectedTransitName == null)) ...[
                      const SizedBox(width: AppSpacing.xs),
                      Tooltip(
                        message: transitError ?? 'Show nearby official stops',
                        child: ActionChip(
                          avatar: Icon(
                            selectedTransitName == null
                                ? Icons.directions_transit
                                : Icons.check_circle,
                            size: 17,
                          ),
                          label: Text(transitLabel),
                          onPressed: onTransitTap,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              FilledButton(
                key: const Key('primary_trip_action'),
                onPressed: primaryAction,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                child: Text(primaryLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, size: 17), const SizedBox(width: 6), Text(label)],
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
