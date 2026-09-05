import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'osrm_routing_service.dart';

class GeoPlace {
  const GeoPlace({
    required this.name,
    required this.address,
    required this.point,
  });

  final String name;
  final String address;
  final LatLng point;

  String get bookingLabel {
    if (address.isEmpty || address.toLowerCase() == name.toLowerCase()) {
      return name;
    }
    return '$name, $address';
  }

  String get subtitle =>
      address.toLowerCase() == name.toLowerCase() ? '' : address;

  factory GeoPlace.coordinate(LatLng point, {String name = 'Pinned location'}) {
    return GeoPlace(
      name: name,
      address:
          '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
      point: point,
    );
  }

  factory GeoPlace.fromPhotonFeature(Map<String, dynamic> feature) {
    final geometry = feature['geometry'] as Map<String, dynamic>? ?? const {};
    final coordinates = geometry['coordinates'] as List<dynamic>? ?? const [];
    if (coordinates.length < 2) {
      throw const FormatException('Location result has no coordinates.');
    }

    final properties =
        feature['properties'] as Map<String, dynamic>? ?? const {};
    final point = LatLng(
      (coordinates[1] as num).toDouble(),
      (coordinates[0] as num).toDouble(),
    );
    final street = _joinNonEmpty([
      _text(properties['housenumber']),
      _text(properties['street']),
    ], separator: ' ');
    final address = _joinUnique([
      street,
      _text(properties['district']),
      _text(properties['city']),
      _text(properties['county']),
      _text(properties['state']),
      _text(properties['postcode']),
      _text(properties['country']),
    ]);
    final name = _text(properties['name']).isNotEmpty
        ? _text(properties['name'])
        : street.isNotEmpty
        ? street
        : _text(properties['city']).isNotEmpty
        ? _text(properties['city'])
        : 'Pinned location';

    return GeoPlace(name: name, address: address, point: point);
  }
}

class LocationSearchException implements Exception {
  const LocationSearchException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PhotonLocationSearchService {
  PhotonLocationSearchService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;
  final Map<String, List<GeoPlace>> _cache = {};

  Future<List<GeoPlace>> search(String query, {LatLng? near}) async {
    final normalized = query.trim();
    if (normalized.length < 3) {
      return const [];
    }

    final cacheKey =
        '${normalized.toLowerCase()}|'
        '${near?.latitude.toStringAsFixed(2)}|'
        '${near?.longitude.toStringAsFixed(2)}';
    final cached = _cache[cacheKey];
    if (cached != null) {
      return cached;
    }

    final parameters = <String, String>{
      'q': normalized,
      'limit': '10',
      'lang': 'en',
      'bbox': kPeninsularMyPhotonBbox,
    };
    if (near != null) {
      parameters['lat'] = near.latitude.toString();
      parameters['lon'] = near.longitude.toString();
    }

    final uri = Uri.https('photon.komoot.io', '/api/', parameters);
    final places = await _getPlaces(uri, filterToRegion: true);
    if (_cache.length >= 50) {
      _cache.clear();
    }
    _cache[cacheKey] = places;
    return places;
  }

  Future<GeoPlace?> reverse(LatLng point) async {
    final uri = Uri.https('photon.komoot.io', '/reverse', {
      'lat': point.latitude.toString(),
      'lon': point.longitude.toString(),
      'lang': 'en',
    });
    final places = await _getPlaces(uri, filterToRegion: false);
    return places.isEmpty ? null : places.first;
  }

  Future<List<GeoPlace>> _getPlaces(
    Uri uri, {
    required bool filterToRegion,
  }) async {
    try {
      final response = await _client
          .get(
            uri,
            headers: const {
              'Accept': 'application/geo+json',
              'User-Agent': 'InfraGo-Mobile/1.0 (BMIT2073 student project)',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw LocationSearchException(
          'Location search is temporarily unavailable (${response.statusCode}).',
        );
      }

      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final features = payload['features'] as List<dynamic>? ?? const [];
      var parsed = features
          .whereType<Map<String, dynamic>>()
          .map(GeoPlace.fromPhotonFeature)
          .toList(growable: false);
      if (filterToRegion) {
        parsed = parsed
            .where((place) => isInsidePeninsularMalaysia(place.point))
            .toList(growable: false);
      }
      final seen = <String>{};
      return parsed
          .where((place) => seen.add(place.bookingLabel.toLowerCase()))
          .take(6)
          .toList(growable: false);
    } on LocationSearchException {
      rethrow;
    } on FormatException {
      throw const LocationSearchException(
        'The location service returned an invalid response.',
      );
    } catch (_) {
      throw const LocationSearchException(
        'Could not search locations. Check your internet connection.',
      );
    }
  }

  void close() => _client.close();
}

String _text(Object? value) => value?.toString().trim() ?? '';

String _joinNonEmpty(List<String> values, {String separator = ', '}) =>
    values.where((value) => value.isNotEmpty).join(separator);

String _joinUnique(List<String> values) {
  final seen = <String>{};
  return values
      .where((value) {
        if (value.isEmpty) {
          return false;
        }
        return seen.add(value.toLowerCase());
      })
      .join(', ');
}
