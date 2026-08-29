import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'location_search_service.dart';
import 'osrm_routing_service.dart';

void unawaited(Future<void>? _) {}

typedef AsyncTripCallback = FutureOr<void> Function();

enum TripPlannerPhase {
  explore,
  routePreview,
  vehicleOptions,
  pickupConfirmation,
  searchingDriver,
  driverAssigned,
  enRoute,
  completed,
  cancelled,
}

class TripPlanRoute {
  const TripPlanRoute({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;

  String get etaText {
    final minutes = (durationSeconds / 60).round();
    if (minutes < 1) return '< 1 min';
    if (minutes < 60) return '$minutes min';
    return '${minutes ~/ 60}h ${minutes % 60}m';
  }

  String get distanceText {
    if (distanceMeters < 1000) return '${distanceMeters.round()} m';
    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }
}

class VehicleOption {
  const VehicleOption({
    required this.id,
    required this.name,
    required this.seats,
    this.currency = 'MYR',
    this.estimatedFareMin,
    this.estimatedFareMax,
    this.isShared = false,
  });

  final String id;
  final String name;
  final int seats;
  final String currency;
  final double? estimatedFareMin;
  final double? estimatedFareMax;
  final bool isShared;

  String get fareLabel {
    final lo = estimatedFareMin;
    final hi = estimatedFareMax;
    if (lo == null && hi == null) return 'Estimate pending';
    if (lo != null && hi != null && (lo - hi).abs() > 0.01) {
      return '$currency ${lo.toStringAsFixed(2)} – ${hi.toStringAsFixed(2)}';
    }
    final value = lo ?? hi!;
    return '$currency ${value.toStringAsFixed(2)}';
  }
}

class AssignedDriverInfo {
  const AssignedDriverInfo({
    required this.driverId,
    required this.name,
    required this.rating,
    required this.vehicleMake,
    required this.vehicleModel,
    required this.vehiclePlate,
    required this.vehicleColor,
    required this.etaMinutes,
    this.exactLocation,
    this.phoneLastFour,
  });

  final String driverId;
  final String name;
  final double rating;
  final String vehicleMake;
  final String vehicleModel;
  final String vehiclePlate;
  final String vehicleColor;
  final int etaMinutes;
  final LatLng? exactLocation;
  final String? phoneLastFour;

  String get vehicleSummary => '$vehicleColor $vehicleMake $vehicleModel';
  String get etaLabel => etaMinutes <= 0 ? 'Arriving' : '$etaMinutes min away';
}

class TripPlannerState extends ChangeNotifier {
  TripPlannerState({required this.routing, required this.search});

  final OsrmRoutingService routing;
  final PhotonLocationSearchService search;

  TripPlannerPhase _phase = TripPlannerPhase.explore;
  GeoPlace? _pickup;
  GeoPlace? _destination;
  TripPlanRoute? _route;
  VehicleOption? _selectedVehicle;
  int _passengerCount = 1;
  DateTime? _scheduledDeparture;
  String? _activeRideId;
  AssignedDriverInfo? _assignedDriver;
  String? _pickupNote;
  String? _errorMessage;
  bool _isLoadingRoute = false;
  bool _isSubmittingRequest = false;
  DateTime? _searchingSince;
  Timer? _cancelDeadline;
  int _cancelCountdownSeconds = 0;
  StreamSubscription<dynamic>? _driverPresenceSubscription;
  StreamSubscription<dynamic>? _rideSubscription;
  final List<AsyncTripCallback> _onRequestSubmitted = [];
  final List<AsyncTripCallback> _onCancelRequested = [];
  int _routeRequestGeneration = 0;
  bool _disposed = false;

  TripPlannerPhase get phase => _phase;
  GeoPlace? get pickup => _pickup;
  GeoPlace? get destination => _destination;
  TripPlanRoute? get route => _route;
  VehicleOption? get selectedVehicle => _selectedVehicle;
  int get passengerCount => _passengerCount;
  DateTime? get scheduledDeparture => _scheduledDeparture;
  DateTime get effectiveDeparture => _scheduledDeparture ?? DateTime.now();
  String? get activeRideId => _activeRideId;
  AssignedDriverInfo? get assignedDriver => _assignedDriver;
  String? get pickupNote => _pickupNote;
  String? get errorMessage => _errorMessage;
  bool get isLoadingRoute => _isLoadingRoute;
  bool get isSubmittingRequest => _isSubmittingRequest;
  DateTime? get searchingSince => _searchingSince;
  int get cancelCountdownSeconds => _cancelCountdownSeconds;

  bool get canCancelForFree =>
      _phase == TripPlannerPhase.searchingDriver ||
      (_phase == TripPlannerPhase.driverAssigned &&
          _cancelCountdownSeconds > 0);

  bool get routeReady =>
      _pickup != null && _destination != null && _route != null;

  void setPickup(GeoPlace place) {
    if (_pickup == place) return;
    _pickup = place;
    _errorMessage = null;
    unawaited(_maybeComputeRoute());
    _advanceAfterLocationChange();
    notifyListeners();
  }

  void setDestination(GeoPlace place) {
    if (_destination == place) return;
    _destination = place;
    _errorMessage = null;
    unawaited(_maybeComputeRoute());
    _advanceAfterLocationChange();
    notifyListeners();
  }

  void setPickupNote(String? note) {
    final value = note?.trim();
    if (value == _pickupNote) return;
    _pickupNote = value?.isEmpty == true ? null : value;
    notifyListeners();
  }

  void selectVehicle(VehicleOption option) {
    if (_phase.index < TripPlannerPhase.routePreview.index) return;
    _selectedVehicle = option;
    final maximum = option.isShared ? 2 : option.seats;
    _passengerCount = _passengerCount.clamp(1, maximum);
    _phase = TripPlannerPhase.vehicleOptions;
    notifyListeners();
  }

  void setRidePreferences({
    required int passengerCount,
    DateTime? scheduledDeparture,
  }) {
    final vehicle = _selectedVehicle;
    if (vehicle == null) return;
    final maximum = vehicle.isShared ? 2 : vehicle.seats;
    if (passengerCount < 1 || passengerCount > maximum) {
      throw ArgumentError.value(
        passengerCount,
        'passengerCount',
        'Must be between 1 and $maximum for ${vehicle.id}.',
      );
    }
    if (scheduledDeparture != null) {
      final now = DateTime.now();
      if (scheduledDeparture.isBefore(now.add(const Duration(minutes: 14))) ||
          scheduledDeparture.isAfter(now.add(const Duration(days: 7)))) {
        throw ArgumentError.value(
          scheduledDeparture,
          'scheduledDeparture',
          'Scheduled rides must be 15 minutes to 7 days ahead.',
        );
      }
    }
    _passengerCount = passengerCount;
    _scheduledDeparture = scheduledDeparture;
    notifyListeners();
  }

  void setActiveRideId(String rideId) {
    _activeRideId = rideId;
  }

  void proceedToPickupConfirmation() {
    if (_selectedVehicle == null) return;
    _phase = TripPlannerPhase.pickupConfirmation;
    notifyListeners();
  }

  Future<bool> submitRideRequest() async {
    if (_phase != TripPlannerPhase.pickupConfirmation) return false;
    if (_pickup == null || _destination == null) return false;
    if (_selectedVehicle == null) return false;
    _isSubmittingRequest = true;
    _errorMessage = null;
    notifyListeners();
    try {
      for (final cb in List.of(_onRequestSubmitted)) {
        await cb();
      }
      _phase = TripPlannerPhase.searchingDriver;
      _searchingSince = DateTime.now();
      return true;
    } catch (e) {
      _errorMessage = e.toString();
      return false;
    } finally {
      _isSubmittingRequest = false;
      notifyListeners();
    }
  }

  void markDriverAssigned(AssignedDriverInfo info) {
    final wasAssigned = _assignedDriver != null;
    _assignedDriver = info;
    if (_phase.index < TripPlannerPhase.driverAssigned.index) {
      _phase = TripPlannerPhase.driverAssigned;
    }
    if (!wasAssigned) _startCancelCountdown(const Duration(minutes: 3));
    notifyListeners();
  }

  void markEnRoute() {
    if (_phase.index < TripPlannerPhase.enRoute.index) {
      _phase = TripPlannerPhase.enRoute;
    }
    notifyListeners();
  }

  void markCompleted() {
    _phase = TripPlannerPhase.completed;
    _teardownActiveSubscriptions();
    notifyListeners();
  }

  void markCancelledFromServer({String? reason}) {
    _errorMessage = reason;
    _phase = TripPlannerPhase.cancelled;
    _teardownActiveSubscriptions();
    notifyListeners();
  }

  void cancelCurrentFlow({String? reason}) {
    _errorMessage = reason;
    _phase = TripPlannerPhase.cancelled;
    for (final cb in List.of(_onCancelRequested)) {
      final result = cb();
      if (result is Future<void>) unawaited(result);
    }
    _teardownActiveSubscriptions();
    notifyListeners();
  }

  void resetToExplore({GeoPlace? keepPickup}) {
    _teardownActiveSubscriptions();
    _phase = TripPlannerPhase.explore;
    _destination = null;
    _route = null;
    _selectedVehicle = null;
    _passengerCount = 1;
    _scheduledDeparture = null;
    _activeRideId = null;
    _assignedDriver = null;
    _pickupNote = null;
    _errorMessage = null;
    _searchingSince = null;
    _cancelCountdownSeconds = 0;
    if (keepPickup != null) _pickup = keepPickup;
    notifyListeners();
  }

  void goBack() {
    switch (_phase) {
      case TripPlannerPhase.explore:
        break;
      case TripPlannerPhase.routePreview:
        _phase = TripPlannerPhase.explore;
      case TripPlannerPhase.vehicleOptions:
        _phase = TripPlannerPhase.routePreview;
        _selectedVehicle = null;
      case TripPlannerPhase.pickupConfirmation:
        _phase = TripPlannerPhase.vehicleOptions;
      case TripPlannerPhase.searchingDriver:
      case TripPlannerPhase.driverAssigned:
      case TripPlannerPhase.enRoute:
      case TripPlannerPhase.completed:
      case TripPlannerPhase.cancelled:
        break;
    }
    notifyListeners();
  }

  void registerRideSubscriptions({
    StreamSubscription<dynamic>? driverPresence,
    StreamSubscription<dynamic>? ride,
  }) {
    _driverPresenceSubscription?.cancel();
    _rideSubscription?.cancel();
    _driverPresenceSubscription = driverPresence;
    _rideSubscription = ride;
  }

  void onRequestSubmitted(AsyncTripCallback cb) => _onRequestSubmitted.add(cb);
  void onCancelRequested(AsyncTripCallback cb) => _onCancelRequested.add(cb);

  void _advanceAfterLocationChange() {
    if (_phase == TripPlannerPhase.explore &&
        _pickup != null &&
        _destination != null) {
      _phase = TripPlannerPhase.routePreview;
    }
  }

  Future<void> _maybeComputeRoute() async {
    final requestGeneration = ++_routeRequestGeneration;
    final pickup = _pickup;
    final destination = _destination;
    if (pickup == null || destination == null) {
      _route = null;
      return;
    }
    _isLoadingRoute = true;
    notifyListeners();
    try {
      final result = await routing.route(pickup.point, destination.point);
      if (_disposed ||
          requestGeneration != _routeRequestGeneration ||
          _pickup != pickup ||
          _destination != destination) {
        return;
      }
      _route = TripPlanRoute(
        points: result.points,
        distanceMeters: result.distanceMeters,
        durationSeconds: result.durationSeconds,
      );
      if (_phase == TripPlannerPhase.explore) {
        _phase = TripPlannerPhase.routePreview;
      }
      _errorMessage = null;
    } on RoutingException catch (e) {
      if (_disposed || requestGeneration != _routeRequestGeneration) return;
      _errorMessage = e.message;
      _route = null;
    } finally {
      if (!_disposed && requestGeneration == _routeRequestGeneration) {
        _isLoadingRoute = false;
        notifyListeners();
      }
    }
  }

  void _startCancelCountdown(Duration freeWindow) {
    _cancelCountdownSeconds = freeWindow.inSeconds;
    _cancelDeadline?.cancel();
    _cancelDeadline = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_disposed) {
        t.cancel();
        return;
      }
      if (_cancelCountdownSeconds <= 0) {
        t.cancel();
        return;
      }
      _cancelCountdownSeconds--;
      notifyListeners();
    });
  }

  void _teardownActiveSubscriptions() {
    _driverPresenceSubscription?.cancel();
    _rideSubscription?.cancel();
    _driverPresenceSubscription = null;
    _rideSubscription = null;
    _cancelDeadline?.cancel();
    _cancelDeadline = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _routeRequestGeneration++;
    _teardownActiveSubscriptions();
    _onRequestSubmitted.clear();
    _onCancelRequested.clear();
    super.dispose();
  }
}

String formatCountdown(int totalSeconds) {
  if (totalSeconds <= 0) return '0:00';
  final m = totalSeconds ~/ 60;
  final s = totalSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
