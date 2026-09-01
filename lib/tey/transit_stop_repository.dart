import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'package:infra_go/kueh/osrm_routing_service.dart';

abstract class TransitStop {
  String get id;
  String get name;
  String? get code;
  String? get route;
  LatLng get location;
  String? get source;
  DateTime? get lastUpdated;

  bool get isStale {
    final u = lastUpdated;
    if (u == null) return true;
    return DateTime.now().difference(u) > const Duration(hours: 6);
  }
}

class TransitStopValue implements TransitStop {
  const TransitStopValue({
    required this.id,
    required this.name,
    required this.location,
    this.code,
    this.route,
    this.source,
    this.lastUpdated,
  });

  @override
  final String id;
  @override
  final String name;
  @override
  final String? code;
  @override
  final String? route;
  @override
  final LatLng location;
  @override
  final String? source;
  @override
  final DateTime? lastUpdated;

  @override
  bool get isStale {
    final u = lastUpdated;
    if (u == null) return true;
    return DateTime.now().difference(u) > const Duration(hours: 6);
  }
}

class NearbyTransitStop {
  const NearbyTransitStop({required this.stop, required this.distanceMeters});

  final TransitStop stop;
  final double distanceMeters;

  String get distanceLabel => distanceMeters < 1000
      ? '${distanceMeters.round()} m'
      : '${(distanceMeters / 1000).toStringAsFixed(1)} km';
}

enum TransitDataStatus { loading, fresh, stale, empty, error }

class TransitRepositoryException implements Exception {
  const TransitRepositoryException(this.message);
  final String message;
  @override
  String toString() => message;
}

class TransitRepositoryResult {
  const TransitRepositoryResult({
    required this.status,
    this.stops = const [],
    this.source,
    this.datasetTimestamp,
    this.errorMessage,
  });

  final TransitDataStatus status;
  final List<TransitStop> stops;
  final String? source;
  final DateTime? datasetTimestamp;
  final String? errorMessage;
}

abstract class TransitStopRepository {
  Future<List<NearbyTransitStop>> nearest(
    LatLng center, {
    int limit = 5,
    double radiusMeters = 2000,
  });
}

typedef TransitStopRowsLoader = Future<List<Map<String, dynamic>>> Function();

class DatabaseTransitStopRepository implements TransitStopRepository {
  DatabaseTransitStopRepository(this.loadRows);

  final TransitStopRowsLoader loadRows;

  @override
  Future<List<NearbyTransitStop>> nearest(
    LatLng center, {
    int limit = 5,
    double radiusMeters = 2000,
  }) async {
    List<Map<String, dynamic>> rows;
    try {
      rows = await loadRows();
    } catch (error) {
      throw TransitRepositoryException(
        'Official GTFS stop data is unavailable: $error',
      );
    }

    final nearby = <NearbyTransitStop>[];
    for (final row in rows) {
      final latitude = (row['latitude'] as num?)?.toDouble();
      final longitude = (row['longitude'] as num?)?.toDouble();
      final id = row['stop_id']?.toString();
      final name = row['stop_name']?.toString();
      if (latitude == null || longitude == null || id == null || name == null) {
        continue;
      }
      final stop = TransitStopValue(
        id: id,
        name: name,
        code: row['stop_code']?.toString(),
        route: row['route_name']?.toString(),
        location: LatLng(latitude, longitude),
        source: row['source']?.toString() ?? 'data.gov.my GTFS Static',
        lastUpdated: DateTime.tryParse(row['updated_at']?.toString() ?? ''),
      );
      final distance = haversineMeters(center, stop.location);
      if (distance <= radiusMeters) {
        nearby.add(NearbyTransitStop(stop: stop, distanceMeters: distance));
      }
    }
    nearby.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return nearby.take(limit).toList(growable: false);
  }
}

class FakeTransitStopRepository implements TransitStopRepository {
  FakeTransitStopRepository(this._stops, {this.delay = Duration.zero});

  final List<TransitStop> _stops;
  final Duration delay;

  @override
  Future<List<NearbyTransitStop>> nearest(
    LatLng center, {
    int limit = 5,
    double radiusMeters = 2000,
  }) async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final out = <NearbyTransitStop>[];
    for (final s in _stops) {
      final d = haversineMeters(center, s.location);
      if (d <= radiusMeters) {
        out.add(NearbyTransitStop(stop: s, distanceMeters: d));
      }
    }
    out.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return out.take(limit).toList(growable: false);
  }
}

// ---------------------------------------------------------------------------
// T2 GTFS Static downloader + parser + cache for Malaysia data.gov.my
// ---------------------------------------------------------------------------

const String kDefaultGtfsStaticSource =
    'https://data.gov.my/gtfs/static/prasarana/stops.txt';
const Duration kGtfsStaleThreshold = Duration(hours: 6);
const String kDefaultSourceLabel = 'data.gov.my GTFS Static';

typedef GtfsHttpDownloader = Future<String> Function(Uri url);
typedef GtfsCacheLoader = Future<({String csv, DateTime fetchedAt})?> Function();
typedef GtfsCacheSaver = Future<void> Function({
  required String csv,
  required DateTime fetchedAt,
});

Future<String> defaultGtfsHttpDownloader(Uri url) async {
  final response = await http.get(url);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw TransitRepositoryException(
      'GTFS download failed: HTTP ${response.statusCode}',
    );
  }
  return utf8.decode(response.bodyBytes, allowMalformed: true);
}

List<String> parseCsvLine(String line) {
  final out = <String>[];
  var buffer = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (inQuotes) {
      if (c == '"' && i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++;
      } else if (c == '"') {
        inQuotes = false;
      } else {
        buffer.write(c);
      }
    } else {
      if (c == ',') {
        out.add(buffer.toString());
        buffer = StringBuffer();
      } else if (c == '"' && buffer.isEmpty) {
        inQuotes = true;
      } else {
        buffer.write(c);
      }
    }
  }
  out.add(buffer.toString());
  return out;
}

List<TransitStop> parseGtfsStopsCsv(
  String csv, {
  String source = kDefaultSourceLabel,
  DateTime? fetchedAt,
  void Function(int line, String reason)? onMalformed,
}) {
  final lines = LineSplitter.split(csv).where((l) => l.trim().isNotEmpty).toList();
  if (lines.length < 2) return const [];

  final header = parseCsvLine(lines.first);
  final idCol = header.indexWhere((h) => h.trim().toLowerCase() == 'stop_id');
  final nameCol = header.indexWhere((h) => h.trim().toLowerCase() == 'stop_name');
  final latCol = header.indexWhere((h) => h.trim().toLowerCase() == 'stop_lat');
  final lonCol = header.indexWhere((h) => h.trim().toLowerCase() == 'stop_lon');
  final codeCol = header.indexWhere((h) => h.trim().toLowerCase() == 'stop_code');

  if (idCol < 0 || nameCol < 0 || latCol < 0 || lonCol < 0) {
    throw const TransitRepositoryException(
      'Malformed GTFS stops.txt: header is missing stop_id/stop_name/stop_lat/stop_lon',
    );
  }

  final seenIds = <String>{};
  final out = <TransitStop>[];
  for (var i = 1; i < lines.length; i++) {
    final lineNumber = i + 1;
    final cells = parseCsvLine(lines[i]);
    String getC(int col) => col >= 0 && col < cells.length ? cells[col].trim() : '';
    final id = getC(idCol);
    final name = getC(nameCol);
    final latRaw = getC(latCol);
    final lonRaw = getC(lonCol);
    final code = codeCol >= 0 ? getC(codeCol) : '';

    if (id.isEmpty || name.isEmpty || latRaw.isEmpty || lonRaw.isEmpty) {
      onMalformed?.call(lineNumber, 'empty required column');
      continue;
    }
    if (seenIds.contains(id)) {
      onMalformed?.call(lineNumber, 'duplicate stop_id: $id');
      continue;
    }
    final lat = double.tryParse(latRaw);
    final lon = double.tryParse(lonRaw);
    if (lat == null || lon == null) {
      onMalformed?.call(lineNumber, 'invalid lat/lon: $latRaw / $lonRaw');
      continue;
    }
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      onMalformed?.call(lineNumber, 'out-of-range lat/lon');
      continue;
    }
    seenIds.add(id);
    out.add(TransitStopValue(
      id: id,
      name: name,
      location: LatLng(lat, lon),
      code: code.isEmpty ? null : code,
      source: source,
      lastUpdated: fetchedAt,
    ));
  }
  return List.unmodifiable(out);
}

class GtfsStaticStopRepository implements TransitStopRepository {
  GtfsStaticStopRepository({
    this.remoteUrl = kDefaultGtfsStaticSource,
    this.sourceLabel = kDefaultSourceLabel,
    GtfsHttpDownloader? downloader,
    this.cacheLoader,
    this.cacheSaver,
    this.staleThreshold = kGtfsStaleThreshold,
    this.onMalformed,
  }) : _downloader = downloader ?? defaultGtfsHttpDownloader;

  final String remoteUrl;
  final String sourceLabel;
  final GtfsHttpDownloader _downloader;
  final GtfsCacheLoader? cacheLoader;
  final GtfsCacheSaver? cacheSaver;
  final Duration staleThreshold;
  final void Function(int line, String reason)? onMalformed;

  List<TransitStop>? _memoryCache;
  DateTime? _memoryCacheFetchedAt;
  Completer<TransitRepositoryResult>? _refreshLock;

  bool get hasCachedStops => _memoryCache?.isNotEmpty ?? false;

  Future<TransitRepositoryResult> loadData({
    bool forceRefresh = false,
  }) async {
    final lock = _refreshLock;
    if (lock != null && !lock.isCompleted) {
      return lock.future;
    }
    final completer = _refreshLock = Completer<TransitRepositoryResult>();
    try {
      final result = await _doLoad(forceRefresh: forceRefresh);
      completer.complete(result);
      return result;
    } catch (error) {
      final fallback = await _fallbackToCacheOrError(error);
      completer.complete(fallback);
      return fallback;
    } finally {
      if (identical(_refreshLock, completer)) _refreshLock = null;
    }
  }

  Future<TransitRepositoryResult> _doLoad({bool forceRefresh = false}) async {
    final now = DateTime.now();
    final cached = _memoryCache;
    final cachedAt = _memoryCacheFetchedAt;
    if (!forceRefresh && cached != null && cachedAt != null) {
      final age = now.difference(cachedAt);
      if (age <= staleThreshold) {
        return TransitRepositoryResult(
          status: TransitDataStatus.fresh,
          stops: cached,
          source: sourceLabel,
          datasetTimestamp: cachedAt,
        );
      }
    }

    final persistent = (cacheLoader != null) ? await cacheLoader!() : null;
    if (!forceRefresh &&
        persistent != null &&
        (cached == null ||
            persistent.fetchedAt.isAfter(cachedAt ?? DateTime.fromMillisecondsSinceEpoch(0)))) {
      final parsed = parseGtfsStopsCsv(
        persistent.csv,
        source: sourceLabel,
        fetchedAt: persistent.fetchedAt,
        onMalformed: onMalformed,
      );
      _memoryCache = parsed;
      _memoryCacheFetchedAt = persistent.fetchedAt;
      final age = now.difference(persistent.fetchedAt);
      return TransitRepositoryResult(
        status: age > staleThreshold ? TransitDataStatus.stale : TransitDataStatus.fresh,
        stops: parsed,
        source: sourceLabel,
        datasetTimestamp: persistent.fetchedAt,
      );
    }

    String csv;
    try {
      csv = await _downloader(Uri.parse(remoteUrl));
    } catch (error) {
      if (cached != null && cachedAt != null) {
        return TransitRepositoryResult(
          status: TransitDataStatus.stale,
          stops: cached,
          source: sourceLabel,
          datasetTimestamp: cachedAt,
          errorMessage: 'Could not refresh GTFS data: $error',
        );
      }
      rethrow;
    }

    final fetchedAt = DateTime.now();
    final parsed = parseGtfsStopsCsv(
      csv,
      source: sourceLabel,
      fetchedAt: fetchedAt,
      onMalformed: onMalformed,
    );
    _memoryCache = parsed;
    _memoryCacheFetchedAt = fetchedAt;
    try {
      await cacheSaver?.call(csv: csv, fetchedAt: fetchedAt);
    } catch (_) {
      // Persistence cache is best-effort; keep the in-memory result.
    }
    return TransitRepositoryResult(
      status: parsed.isEmpty ? TransitDataStatus.empty : TransitDataStatus.fresh,
      stops: parsed,
      source: sourceLabel,
      datasetTimestamp: fetchedAt,
    );
  }

  Future<TransitRepositoryResult> _fallbackToCacheOrError(Object error) async {
    final cached = _memoryCache;
    final cachedAt = _memoryCacheFetchedAt;
    if (cached != null && cachedAt != null) {
      return TransitRepositoryResult(
        status: TransitDataStatus.stale,
        stops: cached,
        source: sourceLabel,
        datasetTimestamp: cachedAt,
        errorMessage: error.toString(),
      );
    }
    return TransitRepositoryResult(
      status: TransitDataStatus.error,
      stops: const [],
      source: sourceLabel,
      errorMessage: error.toString(),
    );
  }

  @override
  Future<List<NearbyTransitStop>> nearest(
    LatLng center, {
    int limit = 5,
    double radiusMeters = 2000,
  }) async {
    final result = await loadData();
    if (result.status == TransitDataStatus.error) {
      throw TransitRepositoryException(
        result.errorMessage ?? 'Official GTFS stop data is unavailable.',
      );
    }
    final nearby = <NearbyTransitStop>[];
    for (final s in result.stops) {
      final d = haversineMeters(center, s.location);
      if (d <= radiusMeters) {
        nearby.add(NearbyTransitStop(stop: s, distanceMeters: d));
      }
    }
    nearby.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    return nearby.take(limit).toList(growable: false);
  }
}
