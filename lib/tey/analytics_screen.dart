import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:infra_go/shared/app_theme.dart';

enum OpenDataStatus { loading, fresh, stale, partial, error, empty }

class OpenDataSeries {
  const OpenDataSeries({
    required this.label,
    required this.points,
    required this.source,
    required this.fetchedAt,
    this.unit,
  });

  final String label;
  final List<(DateTime, double)> points;
  final String source;
  final DateTime fetchedAt;
  final String? unit;

  bool get isStale =>
      DateTime.now().difference(fetchedAt) > const Duration(hours: 24);
}

class FuelPriceSnapshot {
  const FuelPriceSnapshot({
    required this.date,
    required this.ron95,
    required this.ron97,
    required this.diesel,
    required this.fetchedAt,
  });
  final DateTime date;
  final double ron95;
  final double ron97;
  final double diesel;
  final DateTime fetchedAt;
  bool get isStale =>
      DateTime.now().difference(fetchedAt) > const Duration(days: 7);
}

class PrototypeMetrics {
  const PrototypeMetrics({
    required this.completedRides,
    required this.sharedGroups,
    required this.transitLinkedRides,
    required this.avgPassengersPerVehicle,
    required this.avgRiderDetourRatio,
    required this.estimatedSavingsMYR,
    required this.vehicleKmAvoided,
    required this.cancellationRate,
    required this.freeCancellationCount,
    required this.feeCancellationCount,
  });

  final int completedRides;
  final int sharedGroups;
  final int transitLinkedRides;
  final double avgPassengersPerVehicle;
  final double avgRiderDetourRatio;
  final double estimatedSavingsMYR;
  final double vehicleKmAvoided;
  final double cancellationRate;
  final int freeCancellationCount;
  final int feeCancellationCount;
}

const String kVehicleRegSource =
    'https://api.data.gov.my/data-catalogue?id=jpj_registered_vehicles&limit=12';
const String kRidershipSource =
    'https://api.data.gov.my/data-catalogue?id=prasarana_daily_ridership&limit=14';
const String kFuelPriceSource =
    'https://api.data.gov.my/data-catalogue?id=weekly_fuel_prices&limit=4';

typedef OpenDataHttpGetter = Future<http.Response> Function(Uri url);

class OpenDataService {
  OpenDataService({
    OpenDataHttpGetter? httpGet,
    Duration staleThreshold = const Duration(hours: 24),
  })  : _httpGet = httpGet ?? http.get,
        _staleThreshold = staleThreshold;

  final OpenDataHttpGetter _httpGet;
  final Duration _staleThreshold;

  DateTime? _vehicleFetchTime;
  List<(DateTime, double)>? _vehiclePetrolSeries;
  String? _vehicleError;

  DateTime? _ridershipFetchTime;
  List<(DateTime, double)>? _lrtSeries;
  String? _ridershipError;

  DateTime? _fuelFetchTime;
  FuelPriceSnapshot? _fuelSnapshot;
  String? _fuelError;

  OpenDataStatus get overallStatus {
    final fetched = [_vehicleFetchTime, _ridershipFetchTime, _fuelFetchTime];
    final anyLoading = fetched.any((t) => t == null);
    final hasError = _vehicleError != null || _ridershipError != null || _fuelError != null;
    final anyData = _vehiclePetrolSeries?.isNotEmpty == true ||
        _lrtSeries?.isNotEmpty == true ||
        _fuelSnapshot != null;
    if (anyLoading) {
      return OpenDataStatus.loading;
    }
    if (!anyData) {
      return hasError ? OpenDataStatus.error : OpenDataStatus.empty;
    }
    if (hasError && anyData) {
      return OpenDataStatus.partial;
    }
    final now = DateTime.now();
    final anyStale = fetched
        .whereType<DateTime>()
        .any((t) => now.difference(t) > _staleThreshold);
    return anyStale ? OpenDataStatus.stale : OpenDataStatus.fresh;
  }

  Future<void> loadAll() async {
    await Future.wait<void>([
      loadVehicleRegistrations().catchError((_) => null),
      loadRidership().catchError((_) => null),
      loadFuelPrices().catchError((_) => null),
    ]);
  }

  Future<void> loadVehicleRegistrations() async {
    try {
      final resp = await _httpGet(Uri.parse(kVehicleRegSource));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        _vehicleError = 'HTTP ${resp.statusCode}';
        return;
      }
      final body = jsonDecode(resp.body) as List<dynamic>;
      final out = <(DateTime, double)>[];
      for (final row in body) {
        final map = row as Map<String, dynamic>;
        final rawDate = map['date']?.toString() ?? map['date_reg']?.toString();
        final type = (map['type']?.toString() ?? '').toLowerCase();
        final fuel = (map['fuel']?.toString() ?? '').toLowerCase();
        final count = (map['count'] as num?)?.toDouble() ??
            (map['total'] as num?)?.toDouble() ??
            0;
        if (rawDate == null) continue;
        final date = DateTime.tryParse(rawDate);
        if (date == null) continue;
        if (type == 'car' && (fuel.isEmpty || fuel == 'petrol')) {
          out.add((date, count));
        }
      }
      out.sort((a, b) => a.$1.compareTo(b.$1));
      _vehiclePetrolSeries = List.unmodifiable(out);
      _vehicleFetchTime = DateTime.now();
      _vehicleError = null;
    } catch (error) {
      _vehicleError = error.toString();
    }
  }

  Future<void> loadRidership() async {
    try {
      final resp = await _httpGet(Uri.parse(kRidershipSource));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        _ridershipError = 'HTTP ${resp.statusCode}';
        return;
      }
      final body = jsonDecode(resp.body) as List<dynamic>;
      final out = <(DateTime, double)>[];
      for (final row in body) {
        final map = row as Map<String, dynamic>;
        final rawDate = map['date']?.toString();
        final service = (map['service']?.toString() ?? '').toLowerCase();
        final count = (map['ridership'] as num?)?.toDouble() ?? 0;
        if (rawDate == null) continue;
        final date = DateTime.tryParse(rawDate);
        if (date == null) continue;
        if (service == 'lrt' || service.contains('lrt')) {
          out.add((date, count));
        }
      }
      out.sort((a, b) => a.$1.compareTo(b.$1));
      _lrtSeries = List.unmodifiable(out);
      _ridershipFetchTime = DateTime.now();
      _ridershipError = null;
    } catch (error) {
      _ridershipError = error.toString();
    }
  }

  Future<void> loadFuelPrices() async {
    try {
      final resp = await _httpGet(Uri.parse(kFuelPriceSource));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        _fuelError = 'HTTP ${resp.statusCode}';
        return;
      }
      final body = jsonDecode(resp.body) as List<dynamic>;
      if (body.isEmpty) {
        _fuelError = 'empty_response';
        return;
      }
      final latest = body.last as Map<String, dynamic>;
      final rawDate = latest['date']?.toString() ?? '';
      final date = DateTime.tryParse(rawDate) ?? DateTime.now();
      final ron95 = (latest['ron95'] as num?)?.toDouble() ?? 0;
      final ron97 = (latest['ron97'] as num?)?.toDouble() ?? 0;
      final diesel = (latest['diesel'] as num?)?.toDouble() ?? 0;
      _fuelSnapshot = FuelPriceSnapshot(
        date: date,
        ron95: ron95,
        ron97: ron97,
        diesel: diesel,
        fetchedAt: DateTime.now(),
      );
      _fuelFetchTime = _fuelSnapshot!.fetchedAt;
      _fuelError = null;
    } catch (error) {
      _fuelError = error.toString();
    }
  }
}

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key, OpenDataService? service})
      : _service = service;

  final OpenDataService? _service;

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  late OpenDataService _openData;
  OpenDataStatus _status = OpenDataStatus.loading;
  bool _isLoading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _openData = widget._service ?? OpenDataService();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      await _openData.loadAll();
      if (!mounted) return;
      setState(() {
        _status = _openData.overallStatus;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = error.toString();
        _status = OpenDataStatus.error;
      });
    }
  }

  String _formatDate(DateTime dt) =>
      '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics Dashboard'),
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
            _StatusBanner(status: _status, error: _loadError),
            const SizedBox(height: AppSpacing.gutter),
            _OfficialGovernmentDataSection(
              service: _openData,
              scheme: scheme,
              theme: theme,
              formatDate: _formatDate,
            ),
            const SizedBox(height: AppSpacing.lg),
            _InfraGoPrototypeMetricsSection(
              scheme: scheme,
              theme: theme,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status, required this.error});
  final OpenDataStatus status;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, icon, bg, fg) = switch (status) {
      OpenDataStatus.loading => (
          'Loading official data…',
          Icons.cloud_sync_outlined,
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
        ),
      OpenDataStatus.fresh => (
          'Official data LIVE',
          Icons.check_circle_outline,
          scheme.primaryContainer,
          scheme.onPrimaryContainer,
        ),
      OpenDataStatus.stale => (
          'Showing cached data (stale)',
          Icons.history_outlined,
          scheme.secondaryContainer,
          scheme.onSecondaryContainer,
        ),
      OpenDataStatus.partial => (
          'Some official sources failed; showing available data',
          Icons.warning_amber_outlined,
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer,
        ),
      OpenDataStatus.empty => (
          'No data available yet',
          Icons.inbox_outlined,
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
        ),
      OpenDataStatus.error => (
          'Could not load official data',
          Icons.error_outline,
          scheme.errorContainer,
          scheme.onErrorContainer,
        ),
    };
    return Card(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Icon(icon, color: fg),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OfficialGovernmentDataSection extends StatelessWidget {
  const _OfficialGovernmentDataSection({
    required this.service,
    required this.scheme,
    required this.theme,
    required this.formatDate,
  });

  final OpenDataService service;
  final ColorScheme scheme;
  final ThemeData theme;
  final String Function(DateTime) formatDate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.account_balance_outlined, color: scheme.primary),
            const SizedBox(width: AppSpacing.xs),
            Text('Official Government Data',
                style: AppTextStyles.sectionHeader),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Source: data.gov.my • Retrieved directly from official datasets. '
          'These statistics are produced by Malaysian government agencies.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        _FuelPriceCard(
          service: service,
          scheme: scheme,
          theme: theme,
          formatDate: formatDate,
        ),
        const SizedBox(height: AppSpacing.md),
        _SimpleSeriesCard(
          title: 'Petrol Car Registrations (JPJ)',
          source: kVehicleRegSource,
          fetchedAt: service._vehicleFetchTime,
          points: service._vehiclePetrolSeries ?? const [],
          error: service._vehicleError,
          scheme: scheme,
          theme: theme,
          formatDate: formatDate,
          unit: 'vehicles',
        ),
        const SizedBox(height: AppSpacing.md),
        _SimpleSeriesCard(
          title: 'LRT Daily Ridership (Prasarana)',
          source: kRidershipSource,
          fetchedAt: service._ridershipFetchTime,
          points: service._lrtSeries ?? const [],
          error: service._ridershipError,
          scheme: scheme,
          theme: theme,
          formatDate: formatDate,
          unit: 'riders/day',
        ),
      ],
    );
  }
}

class _FuelPriceCard extends StatelessWidget {
  const _FuelPriceCard({
    required this.service,
    required this.scheme,
    required this.theme,
    required this.formatDate,
  });

  final OpenDataService service;
  final ColorScheme scheme;
  final ThemeData theme;
  final String Function(DateTime) formatDate;

  @override
  Widget build(BuildContext context) {
    final snapshot = service._fuelSnapshot;
    final error = service._fuelError;
    final fetchedAt = service._fuelFetchTime;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Weekly Fuel Prices (MOF)',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            _SourceBadge(source: kFuelPriceSource, fetchedAt: fetchedAt, formatDate: formatDate, scheme: scheme, theme: theme, snapshot: snapshot),
            const SizedBox(height: AppSpacing.md),
            if (snapshot != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _PriceTile(label: 'RON95', value: snapshot.ron95, scheme: scheme),
                  _PriceTile(label: 'RON97', value: snapshot.ron97, scheme: scheme),
                  _PriceTile(label: 'Diesel', value: snapshot.diesel, scheme: scheme),
                ],
              )
            else if (error != null)
              Text(
                'Data unavailable: $error',
                style: TextStyle(color: scheme.error),
              )
            else
              const Text('Awaiting official fuel price feed…'),
          ],
        ),
      ),
    );
  }
}

class _PriceTile extends StatelessWidget {
  const _PriceTile({required this.label, required this.value, required this.scheme});
  final String label;
  final double value;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: AppTextStyles.labelCaps),
        const SizedBox(height: 2),
        Text(
          value == 0 ? '-' : 'RM${value.toStringAsFixed(2)}',
          style: AppTextStyles.statsNumeric,
        ),
      ],
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({
    required this.source,
    required this.fetchedAt,
    required this.formatDate,
    required this.scheme,
    required this.theme,
    required this.snapshot,
  });

  final String source;
  final DateTime? fetchedAt;
  final String Function(DateTime) formatDate;
  final ColorScheme scheme;
  final ThemeData theme;
  final FuelPriceSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final stale = fetchedAt != null &&
        DateTime.now().difference(fetchedAt!) > const Duration(hours: 24);
    return Wrap(
      spacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: 2),
          decoration: BoxDecoration(
            color: stale
                ? scheme.secondaryContainer
                : scheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            stale ? 'CACHED (stale)' : 'LIVE',
            style: TextStyle(
              color: stale
                  ? scheme.onSecondaryContainer
                  : scheme.onPrimaryContainer,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Text(
          fetchedAt == null
              ? 'Fetching official source…'
              : 'Fetched ${formatDate(fetchedAt!)}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _SimpleSeriesCard extends StatelessWidget {
  const _SimpleSeriesCard({
    required this.title,
    required this.source,
    required this.fetchedAt,
    required this.points,
    required this.error,
    required this.scheme,
    required this.theme,
    required this.formatDate,
    required this.unit,
  });

  final String title;
  final String source;
  final DateTime? fetchedAt;
  final List<(DateTime, double)> points;
  final String? error;
  final ColorScheme scheme;
  final ThemeData theme;
  final String Function(DateTime) formatDate;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final stale = fetchedAt != null &&
        DateTime.now().difference(fetchedAt!) > const Duration(hours: 24);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: 2),
                  decoration: BoxDecoration(
                    color: error != null
                        ? scheme.errorContainer
                        : stale
                            ? scheme.secondaryContainer
                            : scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    error != null
                        ? 'ERROR'
                        : stale
                            ? 'CACHED (stale)'
                            : 'LIVE',
                    style: TextStyle(
                      color: error != null
                          ? scheme.onErrorContainer
                          : stale
                              ? scheme.onSecondaryContainer
                              : scheme.onPrimaryContainer,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  fetchedAt == null ? 'Fetching…' : 'Fetched ${formatDate(fetchedAt!)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (error != null)
              Text(
                'Official source error: $error',
                style: TextStyle(color: scheme.error),
              )
            else if (points.isEmpty)
              const Text('No data points from the official feed yet.')
            else
              _MiniBarChart(points: points, unit: unit),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Source: data.gov.my • Never treat prototype estimates as government statistics.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniBarChart extends StatelessWidget {
  const _MiniBarChart({required this.points, required this.unit});
  final List<(DateTime, double)> points;
  final String unit;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();
    final max = points
        .map((e) => e.$2)
        .reduce((a, b) => a > b ? a : b);
    const maxBarHeight = 64.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: maxBarHeight + AppSpacing.md,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: points.map((p) {
              final ratio = max == 0 ? 0.0 : (p.$2 / max).clamp(0.0, 1.0);
              return Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  height: maxBarHeight * ratio,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4)),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Latest: ${points.last.$2.toStringAsFixed(0)} $unit • Period: ${points.length} data points',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _InfraGoPrototypeMetricsSection extends StatelessWidget {
  const _InfraGoPrototypeMetricsSection({
    required this.scheme,
    required this.theme,
  });

  final ColorScheme scheme;
  final ThemeData theme;

  PrototypeMetrics _buildPrototypeSample() {
    return const PrototypeMetrics(
      completedRides: 0,
      sharedGroups: 0,
      transitLinkedRides: 0,
      avgPassengersPerVehicle: 0,
      avgRiderDetourRatio: 0,
      estimatedSavingsMYR: 0,
      vehicleKmAvoided: 0,
      cancellationRate: 0,
      freeCancellationCount: 0,
      feeCancellationCount: 0,
    );
  }

  String _pctOrNA(double ratio) {
    if (ratio.isNaN || ratio.isInfinite) return 'N/A';
    return '${(ratio * 100).toStringAsFixed(1)}%';
  }

  @override
  Widget build(BuildContext context) {
    final m = _buildPrototypeSample();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.science_outlined, color: scheme.tertiary),
            const SizedBox(width: AppSpacing.xs),
            Text('InfraGo Prototype Metrics',
                style: AppTextStyles.sectionHeader),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'These are coursework prototype estimates derived from InfraGo ride '
          'data. They are NOT official government statistics.',
          style: TextStyle(
            color: scheme.tertiary,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            _MetricCard(
              title: 'SDG 9.1 Sustainable Mobility',
              scheme: scheme,
              children: [
                _MetricRow('Completed rides', '${m.completedRides}'),
                _MetricRow('Shared groups', '${m.sharedGroups}'),
                _MetricRow('Transit-linked rides', '${m.transitLinkedRides}'),
                _MetricRow('Vehicle-km avoided',
                    '${m.vehicleKmAvoided.toStringAsFixed(1)} km'),
                _MetricRow('Estimated user savings',
                    'RM${m.estimatedSavingsMYR.toStringAsFixed(2)}'),
              ],
            ),
            _MetricCard(
              title: 'Vehicle Utilisation',
              scheme: scheme,
              children: [
                _MetricRow(
                  'Avg passengers / vehicle',
                  m.avgPassengersPerVehicle == 0
                      ? 'N/A'
                      : m.avgPassengersPerVehicle.toStringAsFixed(2),
                ),
                _MetricRow(
                  'Avg rider detour',
                  m.avgRiderDetourRatio == 0
                      ? 'N/A'
                      : _pctOrNA(m.avgRiderDetourRatio),
                ),
              ],
            ),
            _MetricCard(
              title: 'Cancellations',
              scheme: scheme,
              children: [
                _MetricRow(
                  'Overall rate',
                  m.cancellationRate == 0 &&
                          m.freeCancellationCount == 0 &&
                          m.feeCancellationCount == 0
                      ? 'N/A'
                      : _pctOrNA(m.cancellationRate),
                ),
                _MetricRow('Free cancelled', '${m.freeCancellationCount}'),
                _MetricRow('Fee cancelled', '${m.feeCancellationCount}'),
              ],
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('AI Disclosure (Tey Ying Heng — coursework)',
            style: AppTextStyles.labelCaps),
        const SizedBox(height: AppSpacing.xs),
        const Text(
          'Trae AI assisted this module with code scaffolding, repository '
          'patterns, SQL migration templates and widget layout. Every SQL '
          'policy, RLS gate, status transition and test case was manually '
          'reviewed against the shared team contract before submission. '
          'Tool limitations: no in-editor flutter analyze or git commands '
          'were run by the assistant (toolchain unavailable in this '
          'sandbox); owner reruns and validates the full build locally '
          'before merging.',
          softWrap: true,
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.scheme,
    required this.children,
  });
  final String title;
  final ColorScheme scheme;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.md),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          const SizedBox(width: AppSpacing.sm),
          Text(value,
              style: const TextStyle(fontWeight: FontWeight.bold),
              textAlign: TextAlign.right),
        ],
      ),
    );
  }
}
