import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:infra_go/shared/app_theme.dart';
import 'package:infra_go/shared/supabase_config.dart';
import 'package:infra_go/tey/sdg_analytics_repository.dart';

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

enum AnalyticsDateRange {
  last30Days('Last 30 days'),
  allTime('All time');

  const AnalyticsDateRange(this.label);
  final String label;

  DateTime? get start {
    switch (this) {
      case AnalyticsDateRange.last30Days:
        return DateTime.now().subtract(const Duration(days: 30));
      case AnalyticsDateRange.allTime:
        return null;
    }
  }
}

// Dataset ids verified against https://developer.data.gov.my (the earlier
// ids here did not exist on the live API and always returned HTTP 404).
const String kVehicleRegSource =
    'https://api.data.gov.my/data-catalogue?id=registrations_type_fuel'
    '&filter=petrol@fuel,car@type&sort=-date&limit=12';
const String kRidershipSource =
    'https://api.data.gov.my/data-catalogue?id=ridership_headline'
    '&sort=-date&limit=14';
const String kFuelPriceSource =
    'https://api.data.gov.my/data-catalogue?id=fuelprice'
    '&filter=level@series_type&sort=-date&limit=4';

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
        final rawDate = map['date']?.toString();
        final count = (map['registrations'] as num?)?.toDouble();
        if (rawDate == null || count == null) continue;
        final date = DateTime.tryParse(rawDate);
        if (date == null) continue;
        out.add((date, count));
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
        // rail_lrt_kj = LRT Kelana Jaya line, a Prasarana-operated line.
        final count = (map['rail_lrt_kj'] as num?)?.toDouble();
        if (rawDate == null || count == null) continue;
        final date = DateTime.tryParse(rawDate);
        if (date == null) continue;
        out.add((date, count));
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
      // Server returns newest-first (sort=-date), so the first row is latest.
      final latest = body.first as Map<String, dynamic>;
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
  const AnalyticsScreen({
    super.key,
    OpenDataService? service,
    SdgAnalyticsRepository? sdgRepository,
  })  : _service = service,
        _sdgRepository = sdgRepository;

  final OpenDataService? _service;
  final SdgAnalyticsRepository? _sdgRepository;

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  late OpenDataService _openData;
  late SdgAnalyticsRepository _sdgRepo;
  OpenDataStatus _status = OpenDataStatus.loading;
  bool _isLoading = true;
  String? _loadError;

  AnalyticsDateRange _range = AnalyticsDateRange.last30Days;
  SdgAnalyticsSnapshot? _sdg;
  bool _sdgLoading = true;
  String? _sdgError;

  @override
  void initState() {
    super.initState();
    _openData = widget._service ?? OpenDataService();
    _sdgRepo = widget._sdgRepository ?? SdgAnalyticsRepository(supabase);
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
    await _loadSdgAnalytics();
  }

  Future<void> _loadSdgAnalytics() async {
    setState(() {
      _sdgLoading = true;
      _sdgError = null;
    });
    try {
      final snapshot = await _sdgRepo.fetchSnapshot(start: _range.start);
      if (!mounted) return;
      setState(() {
        _sdg = snapshot;
        _sdgLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sdgLoading = false;
        _sdgError = error.toString();
      });
    }
  }

  void _onRangeChanged(AnalyticsDateRange range) {
    if (range == _range) return;
    setState(() => _range = range);
    unawaited(_loadSdgAnalytics());
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
              snapshot: _sdg,
              loading: _sdgLoading,
              error: _sdgError,
              range: _range,
              onRangeChanged: _onRangeChanged,
              onRetry: _loadSdgAnalytics,
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
    required this.snapshot,
    required this.loading,
    required this.error,
    required this.range,
    required this.onRangeChanged,
    required this.onRetry,
  });

  final ColorScheme scheme;
  final ThemeData theme;
  final SdgAnalyticsSnapshot? snapshot;
  final bool loading;
  final String? error;
  final AnalyticsDateRange range;
  final ValueChanged<AnalyticsDateRange> onRangeChanged;
  final VoidCallback onRetry;

  String _pctOrNA(double? ratio) {
    if (ratio == null || ratio.isNaN || ratio.isInfinite) return 'N/A';
    return '${(ratio * 100).toStringAsFixed(1)}%';
  }

  String _numOrNA(double? value, {int decimals = 2}) {
    if (value == null || value.isNaN || value.isInfinite) return 'N/A';
    return value.toStringAsFixed(decimals);
  }

  @override
  Widget build(BuildContext context) {
    final m = snapshot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.science_outlined, color: scheme.tertiary),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text('InfraGo Prototype Metrics',
                  style: AppTextStyles.sectionHeader),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'These are coursework prototype estimates computed live from '
          'InfraGo ride, group and payment records. They are NOT official '
          'government statistics.',
          style: TextStyle(
            color: scheme.tertiary,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.xs,
          children: AnalyticsDateRange.values.map((r) {
            return ChoiceChip(
              label: Text(r.label),
              selected: range == r,
              onSelected: (_) => onRangeChanged(r),
            );
          }).toList(),
        ),
        const SizedBox(height: AppSpacing.md),
        if (loading && m == null)
          const Center(child: Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: CircularProgressIndicator(),
          ))
        else if (error != null && m == null)
          Card(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Could not load prototype analytics: $error',
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
                ],
              ),
            ),
          )
        else if (m != null)
          _MetricsBody(scheme: scheme, m: m, pctOrNA: _pctOrNA, numOrNA: _numOrNA),
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

class _MetricsBody extends StatelessWidget {
  const _MetricsBody({
    required this.scheme,
    required this.m,
    required this.pctOrNA,
    required this.numOrNA,
  });

  final ColorScheme scheme;
  final SdgAnalyticsSnapshot m;
  final String Function(double?) pctOrNA;
  final String Function(double?, {int decimals}) numOrNA;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            _MetricCard(
              title: 'SDG 9.1 Sustainable Mobility',
              scheme: scheme,
              children: [
                _MetricRow('Completed rides', '${m.completedRides}'),
                _MetricRow('Shared groups', '${m.sharedGroupsCompleted}'),
                _MetricRow(
                    'Transit-linked rides', '${m.transitLinkedRides}'),
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
                  numOrNA(m.avgPassengersPerVehicle),
                ),
                _MetricRow(
                  'Avg rider detour',
                  pctOrNA(m.avgRiderDetourRatio),
                ),
              ],
            ),
            _MetricCard(
              title: 'Cancellations',
              scheme: scheme,
              children: [
                _MetricRow('Overall rate', pctOrNA(m.cancellationRate)),
                _MetricRow('Free cancelled', '${m.freeCancellationCount}'),
                _MetricRow('Fee cancelled', '${m.feeCancellationCount}'),
                _MetricRow('Prototype driver compensation',
                    'RM${m.prototypeDriverCompensationMYR.toStringAsFixed(2)}'),
              ],
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            _MetricCard(
              title: 'Vehicle Capacity Distribution',
              scheme: scheme,
              children: m.vehicleCapacityDistribution.isEmpty
                  ? const [Text('No approved vehicles yet.')]
                  : m.vehicleCapacityDistribution
                      .map((c) => _MetricRow(
                          '${c.capacity}-seater', '${c.count}'))
                      .toList(),
            ),
            _MetricCard(
              title: 'Service Category Distribution',
              scheme: scheme,
              children: m.serviceCategoryDistribution.isEmpty
                  ? const [Text('No completed rides in this range yet.')]
                  : m.serviceCategoryDistribution
                      .map((s) => _MetricRow(s.serviceType, '${s.count}'))
                      .toList(),
            ),
            _MetricCard(
              title: 'Top Cancellation Reasons',
              scheme: scheme,
              children: m.topCancellationReasons.isEmpty
                  ? const [Text('No cancellation reasons recorded yet.')]
                  : m.topCancellationReasons
                      .map((r) => _MetricRow(r.reason, '${r.count}'))
                      .toList(),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _MetricCard(
          title: 'Payment Method / Status Aggregates',
          scheme: scheme,
          children: m.paymentAggregates.isEmpty
              ? const [Text('No payments recorded in this range yet.')]
              : m.paymentAggregates
                  .map((p) => _MetricRow(
                      '${p.method} · ${p.status} (${p.count})',
                      'RM${p.totalMYR.toStringAsFixed(2)}'))
                  .toList(),
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
