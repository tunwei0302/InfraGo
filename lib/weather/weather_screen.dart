import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/kueh/location_search_service.dart';
import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/shared/supabase_config.dart';
import 'package:infra_go/weather/route_weather_service.dart';
import 'package:infra_go/weather/weather_location_repository.dart';

/// Used whenever the device position is unavailable (permission denied,
/// location services off, or a timeout) — keeps the screen useful even
/// without a GPS fix.
const LatLng kWeatherDefaultReferencePoint = LatLng(3.1390, 101.6869);
const String kWeatherDefaultReferenceLabel = 'Kuala Lumpur (default)';

typedef WeatherLocationResolver = Future<(LatLng, String)> Function();

Future<(LatLng, String)> _defaultResolvePoint() async {
  try {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return (kWeatherDefaultReferencePoint, kWeatherDefaultReferenceLabel);
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return (kWeatherDefaultReferencePoint, kWeatherDefaultReferenceLabel);
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    ).timeout(const Duration(seconds: 5));
    return (
      LatLng(position.latitude, position.longitude),
      'Your current location',
    );
  } catch (_) {
    return (kWeatherDefaultReferencePoint, kWeatherDefaultReferenceLabel);
  }
}

class WeatherScreen extends StatefulWidget {
  const WeatherScreen({
    super.key,
    RouteWeatherService? service,
    WeatherLocationResolver? resolveLocation,
    WeatherLocationRepository? locationRepository,
  })  : _service = service,
        _resolveLocation = resolveLocation,
        _locationRepository = locationRepository;

  final RouteWeatherService? _service;
  final WeatherLocationResolver? _resolveLocation;
  final WeatherLocationRepository? _locationRepository;

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  late RouteWeatherService _weather;
  late WeatherLocationResolver _resolvePoint;
  late WeatherLocationRepository _locations;
  final PhotonLocationSearchService _placeSearch = PhotonLocationSearchService();
  bool _isLoading = true;
  WeatherSnapshot? _snapshot;
  String? _error;
  String _locationLabel = kWeatherDefaultReferenceLabel;
  LatLng? _currentPoint;
  String? _selectedLocationId;

  bool _savedLoading = true;
  String? _savedError;
  List<WeatherSavedLocation> _savedLocations = const [];

  @override
  void initState() {
    super.initState();
    _weather = widget._service ?? RouteWeatherService();
    _resolvePoint = widget._resolveLocation ?? _defaultResolvePoint;
    _locations = widget._locationRepository ?? WeatherLocationRepository(supabase);
    unawaited(_refresh());
    unawaited(_loadSavedLocations());
  }

  @override
  void dispose() {
    _placeSearch.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _selectedLocationId = null;
    });
    try {
      final (point, label) = await _resolvePoint();
      final snapshot = await _weather.fetchSnapshot(point);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _locationLabel = label;
        _currentPoint = point;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _viewSavedLocation(WeatherSavedLocation location) async {
    setState(() {
      _isLoading = true;
      _error = null;
      _selectedLocationId = location.id;
    });
    try {
      final snapshot = await _weather.fetchSnapshot(location.point);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _locationLabel = location.label;
        _currentPoint = location.point;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _loadSavedLocations() async {
    setState(() {
      _savedLoading = true;
      _savedError = null;
    });
    try {
      final locations = await _locations.fetchAll();
      if (!mounted) return;
      setState(() {
        _savedLocations = locations;
        _savedLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _savedError = error.toString();
        _savedLoading = false;
      });
    }
  }

  Future<void> _openLocationForm({WeatherSavedLocation? existing}) async {
    final result = await showModalBottomSheet<({String label, LatLng point})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SavedLocationFormSheet(
        searchService: _placeSearch,
        near: _currentPoint,
        title: existing == null ? 'Add saved location' : 'Edit saved location',
        initialLabel: existing?.label,
        initialPoint: existing?.point,
      ),
    );
    if (result == null || !mounted) return;
    try {
      final saved = existing == null
          ? await _locations.create(label: result.label, point: result.point)
          : await _locations.update(
              id: existing.id,
              label: result.label,
              point: result.point,
            );
      if (!mounted) return;
      await _loadSavedLocations();
      if (!mounted) return;
      unawaited(_viewSavedLocation(saved));
    } on WeatherLocationException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _confirmDelete(WeatherSavedLocation location) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete saved location?'),
        content: Text('Remove "${location.label}" from your saved locations?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _locations.delete(location.id);
      if (!mounted) return;
      if (_selectedLocationId == location.id) {
        unawaited(_refresh());
      }
      await _loadSavedLocations();
    } on WeatherLocationException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final snapshot = _snapshot;
    final risk = snapshot == null ? null : WeatherRiskAssessor.classify(snapshot);
    final message = snapshot == null
        ? null
        : WeatherRiskAssessor.messageFor(risk!, _locationLabel);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Weather'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.marginMobile),
          children: [
            if (_isLoading && snapshot == null)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null && snapshot == null)
              Card(
                color: scheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.gutter),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Could not load weather: $_error',
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      ElevatedButton(
                        onPressed: _refresh,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              )
            else if (snapshot != null && risk != null && message != null) ...[
              _RiskBanner(risk: risk, message: message),
              const SizedBox(height: AppSpacing.md),
              _ConditionsCard(
                snapshot: snapshot,
                locationLabel: _locationLabel,
                formatTime: _formatTime,
                scheme: scheme,
                theme: theme,
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            _SavedLocationsSection(
              loading: _savedLoading,
              error: _savedError,
              locations: _savedLocations,
              selectedId: _selectedLocationId,
              onSelect: _viewSavedLocation,
              onUseCurrent: _isLoading ? null : _refresh,
              onAdd: () => _openLocationForm(),
              onEdit: (location) => _openLocationForm(existing: location),
              onDelete: _confirmDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _RiskBanner extends StatelessWidget {
  const _RiskBanner({required this.risk, required this.message});

  final RouteRiskLevel risk;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, icon) = switch (risk) {
      RouteRiskLevel.high => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          Icons.warning_amber_rounded,
        ),
      RouteRiskLevel.caution => (
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer,
          Icons.water_drop_outlined,
        ),
      RouteRiskLevel.none => (
          scheme.primaryContainer,
          scheme.onPrimaryContainer,
          Icons.check_circle_outline,
        ),
    };
    return Card(
      color: background,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Icon(icon, color: foreground),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConditionsCard extends StatelessWidget {
  const _ConditionsCard({
    required this.snapshot,
    required this.locationLabel,
    required this.formatTime,
    required this.scheme,
    required this.theme,
  });

  final WeatherSnapshot snapshot;
  final String locationLabel;
  final String Function(DateTime) formatTime;
  final ColorScheme scheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(locationLabel, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Updated ${formatTime(snapshot.fetchedAt)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _StatTile(label: 'Condition', value: snapshot.condition),
                _StatTile(
                  label: 'Rain',
                  value:
                      '${snapshot.precipitationMmPerHour.toStringAsFixed(1)} mm/h',
                ),
                _StatTile(
                  label: 'Wind',
                  value: '${snapshot.windSpeedKph.toStringAsFixed(0)} km/h',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: AppTextStyles.labelCaps),
        const SizedBox(height: 2),
        Text(value, style: AppTextStyles.statsNumeric),
      ],
    );
  }
}

class _SavedLocationsSection extends StatelessWidget {
  const _SavedLocationsSection({
    required this.loading,
    required this.error,
    required this.locations,
    required this.selectedId,
    required this.onSelect,
    required this.onUseCurrent,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  final bool loading;
  final String? error;
  final List<WeatherSavedLocation> locations;
  final String? selectedId;
  final ValueChanged<WeatherSavedLocation> onSelect;
  final VoidCallback? onUseCurrent;
  final VoidCallback onAdd;
  final ValueChanged<WeatherSavedLocation> onEdit;
  final ValueChanged<WeatherSavedLocation> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Saved locations',
                    style: AppTextStyles.sectionHeader,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_location_alt_outlined),
                  tooltip: 'Add saved location',
                  onPressed: onAdd,
                ),
              ],
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.my_location),
              title: const Text('Current location'),
              selected: selectedId == null,
              onTap: onUseCurrent,
            ),
            if (loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text(
                  'Could not load saved locations: $error',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              )
            else if (locations.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text('No saved locations yet. Tap + to add one.'),
              )
            else
              ...locations.map(
                (location) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.place_outlined),
                  title: Text(location.label),
                  subtitle: Text(
                    '${location.point.latitude.toStringAsFixed(4)}, '
                    '${location.point.longitude.toStringAsFixed(4)}',
                  ),
                  selected: location.id == selectedId,
                  onTap: () => onSelect(location),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Edit',
                        onPressed: () => onEdit(location),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Delete',
                        onPressed: () => onDelete(location),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SavedLocationFormSheet extends StatefulWidget {
  const _SavedLocationFormSheet({
    required this.searchService,
    required this.near,
    required this.title,
    this.initialLabel,
    this.initialPoint,
  });

  final PhotonLocationSearchService searchService;
  final LatLng? near;
  final String title;
  final String? initialLabel;
  final LatLng? initialPoint;

  @override
  State<_SavedLocationFormSheet> createState() =>
      _SavedLocationFormSheetState();
}

class _SavedLocationFormSheetState extends State<_SavedLocationFormSheet> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _labelController = TextEditingController();
  Timer? _debounce;
  List<GeoPlace> _results = const [];
  bool _isSearching = false;
  String? _searchError;
  int _requestNumber = 0;
  GeoPlace? _selectedPlace;
  LatLng? _selectedPoint;

  @override
  void initState() {
    super.initState();
    _labelController.text = widget.initialLabel ?? '';
    _selectedPoint = widget.initialPoint;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.length < 3) {
      setState(() {
        _results = const [];
        _isSearching = false;
        _searchError = null;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 650),
      () => _search(query),
    );
  }

  Future<void> _search(String query) async {
    final requestNumber = ++_requestNumber;
    setState(() {
      _isSearching = true;
      _searchError = null;
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
        _searchError = error.message;
      });
    } finally {
      if (mounted && requestNumber == _requestNumber) {
        setState(() => _isSearching = false);
      }
    }
  }

  void _pickPlace(GeoPlace place) {
    setState(() {
      _selectedPlace = place;
      _selectedPoint = place.point;
      if (_labelController.text.trim().isEmpty) {
        _labelController.text = place.name;
      }
      _results = const [];
      _searchController.clear();
    });
  }

  void _save() {
    final label = _labelController.text.trim();
    final point = _selectedPoint;
    if (label.isEmpty || point == null) return;
    Navigator.pop(context, (label: label, point: point));
  }

  @override
  Widget build(BuildContext context) {
    final canSave =
        _labelController.text.trim().isNotEmpty && _selectedPoint != null;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.gutter,
        right: AppSpacing.gutter,
        top: AppSpacing.gutter,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.gutter,
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
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
            if (_selectedPoint != null) ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.place),
                  title: Text(_selectedPlace?.name ?? 'Selected location'),
                  subtitle: Text(
                    _selectedPlace?.subtitle.isNotEmpty == true
                        ? _selectedPlace!.subtitle
                        : '${_selectedPoint!.latitude.toStringAsFixed(5)}, '
                            '${_selectedPoint!.longitude.toStringAsFixed(5)}',
                  ),
                  trailing: TextButton(
                    onPressed: () => setState(() => _selectedPoint = null),
                    child: const Text('Change'),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _labelController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (_) => setState(() {}),
              ),
              const Spacer(),
            ] else ...[
              TextField(
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onQueryChanged,
                decoration: InputDecoration(
                  hintText: 'Search for a place',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _isSearching
                      ? const Padding(
                          padding: EdgeInsets.all(AppSpacing.sm),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: AppSpacing.base),
              Expanded(child: _buildResults(context)),
            ],
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: canSave ? _save : null,
                child: const Text('Save location'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_searchError != null) {
      return Center(
        child: Text(
          _searchError!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    if (_searchController.text.trim().length < 3) {
      return const Center(
        child: Text('Type at least 3 characters to search.'),
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
      separatorBuilder: (context, index) => const Divider(height: 1),
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
          onTap: () => _pickPlace(place),
        );
      },
    );
  }
}
