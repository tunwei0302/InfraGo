import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/weather/route_weather_service.dart';

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
  })  : _service = service,
        _resolveLocation = resolveLocation;

  final RouteWeatherService? _service;
  final WeatherLocationResolver? _resolveLocation;

  @override
  State<WeatherScreen> createState() => _WeatherScreenState();
}

class _WeatherScreenState extends State<WeatherScreen> {
  late RouteWeatherService _weather;
  late WeatherLocationResolver _resolvePoint;
  bool _isLoading = true;
  WeatherSnapshot? _snapshot;
  String? _error;
  String _locationLabel = kWeatherDefaultReferenceLabel;

  @override
  void initState() {
    super.initState();
    _weather = widget._service ?? RouteWeatherService();
    _resolvePoint = widget._resolveLocation ?? _defaultResolvePoint;
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final (point, label) = await _resolvePoint();
      final snapshot = await _weather.fetchSnapshot(point);
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _locationLabel = label;
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
            Text(
              'Source: Open-Meteo • Live, third-party data — not a data.gov.my '
              'dataset. Risk thresholds are a coursework estimate, not an '
              'official MetMalaysia rainfall-warning classification.',
              style: theme.textTheme.bodySmall,
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
