import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class WeatherFetchException implements Exception {
  const WeatherFetchException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum RouteRiskLevel { none, caution, high }

class WeatherSnapshot {
  const WeatherSnapshot({
    required this.precipitationMmPerHour,
    required this.windSpeedKph,
    required this.condition,
    required this.fetchedAt,
  });

  final double precipitationMmPerHour;
  final double windSpeedKph;
  final String condition;
  final DateTime fetchedAt;
}

class RouteAdvisoryLeg {
  const RouteAdvisoryLeg({
    required this.label,
    required this.snapshot,
    required this.risk,
    required this.message,
  });

  final String label;
  final WeatherSnapshot snapshot;
  final RouteRiskLevel risk;
  final String message;
}

class RouteWeatherAdvisory {
  const RouteWeatherAdvisory({required this.legs});

  final List<RouteAdvisoryLeg> legs;

  RouteRiskLevel get overallRisk {
    if (legs.any((leg) => leg.risk == RouteRiskLevel.high)) {
      return RouteRiskLevel.high;
    }
    if (legs.any((leg) => leg.risk == RouteRiskLevel.caution)) {
      return RouteRiskLevel.caution;
    }
    return RouteRiskLevel.none;
  }

  RouteAdvisoryLeg? get mostSevereLeg {
    for (final level in [RouteRiskLevel.high, RouteRiskLevel.caution]) {
      for (final leg in legs) {
        if (leg.risk == level) return leg;
      }
    }
    return null;
  }
}

class WeatherRiskAssessor {
  const WeatherRiskAssessor._();

  static const double cautionPrecipitationMmPerHour = 5.0;
  static const double highPrecipitationMmPerHour = 20.0;
  static const double cautionWindSpeedKph = 50.0;

  static RouteRiskLevel classify(WeatherSnapshot snapshot) {
    if (snapshot.precipitationMmPerHour >= highPrecipitationMmPerHour) {
      return RouteRiskLevel.high;
    }
    if (snapshot.precipitationMmPerHour >= cautionPrecipitationMmPerHour ||
        snapshot.windSpeedKph >= cautionWindSpeedKph) {
      return RouteRiskLevel.caution;
    }
    return RouteRiskLevel.none;
  }

  static String messageFor(RouteRiskLevel risk, String label) {
    switch (risk) {
      case RouteRiskLevel.high:
        return 'Heavy rain expected near $label — flooding possible on '
            'low-lying roads. Allow extra time.';
      case RouteRiskLevel.caution:
        return 'Rain expected near $label — allow extra time and expect '
            'slower traffic.';
      case RouteRiskLevel.none:
        return 'No significant weather risk near $label.';
    }
  }

  static RouteAdvisoryLeg assess({
    required String label,
    required WeatherSnapshot snapshot,
  }) {
    final risk = classify(snapshot);
    return RouteAdvisoryLeg(
      label: label,
      snapshot: snapshot,
      risk: risk,
      message: messageFor(risk, label),
    );
  }
}

String conditionLabelForWmoCode(int code) {
  if (code == 0) return 'Clear';
  if (code <= 3) return 'Partly cloudy';
  if (code == 45 || code == 48) return 'Fog';
  if (code >= 51 && code <= 67) return 'Rain';
  if (code >= 71 && code <= 77) return 'Snow';
  if (code >= 80 && code <= 82) return 'Rain showers';
  if (code >= 95) return 'Thunderstorm';
  return 'Unknown';
}

typedef WeatherHttpGetter = Future<http.Response> Function(Uri url);

class RouteWeatherService {
  RouteWeatherService({
    WeatherHttpGetter? httpGet,
    this.baseUrl = 'https://api.open-meteo.com/v1/forecast',
  }) : _httpGet = httpGet ?? http.get;

  final WeatherHttpGetter _httpGet;
  final String baseUrl;
  static const Duration _requestTimeout = Duration(seconds: 10);

  Future<WeatherSnapshot> fetchSnapshot(LatLng point) async {
    final uri = Uri.parse(baseUrl).replace(
      queryParameters: {
        'latitude': point.latitude.toStringAsFixed(4),
        'longitude': point.longitude.toStringAsFixed(4),
        'current': 'precipitation,wind_speed_10m,weather_code',
        'timezone': 'auto',
      },
    );

    http.Response response;
    try {
      response = await _httpGet(uri).timeout(_requestTimeout);
    } on WeatherFetchException {
      rethrow;
    } catch (_) {
      throw const WeatherFetchException(
        'Could not reach the weather service. Check your connection.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WeatherFetchException(
        'Weather service returned an error (${response.statusCode}).',
      );
    }
    try {
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final current = payload['current'] as Map<String, dynamic>?;
      if (current == null) {
        throw const WeatherFetchException(
          'Weather response is missing current conditions.',
        );
      }
      final precipitation = (current['precipitation'] as num?)?.toDouble() ?? 0;
      final windSpeed = (current['wind_speed_10m'] as num?)?.toDouble() ?? 0;
      final code = (current['weather_code'] as num?)?.toInt() ?? 0;
      return WeatherSnapshot(
        precipitationMmPerHour: precipitation,
        windSpeedKph: windSpeed,
        condition: conditionLabelForWmoCode(code),
        fetchedAt: DateTime.now(),
      );
    } on WeatherFetchException {
      rethrow;
    } catch (_) {
      throw const WeatherFetchException(
        'The weather service returned an invalid response.',
      );
    }
  }

  Future<RouteWeatherAdvisory> fetchRouteAdvisory({
    required LatLng pickup,
    required LatLng destination,
    String pickupLabel = 'pickup',
    String destinationLabel = 'destination',
  }) async {
    final snapshots = await Future.wait([
      fetchSnapshot(pickup),
      fetchSnapshot(destination),
    ]);
    return RouteWeatherAdvisory(
      legs: [
        WeatherRiskAssessor.assess(label: pickupLabel, snapshot: snapshots[0]),
        WeatherRiskAssessor.assess(
          label: destinationLabel,
          snapshot: snapshots[1],
        ),
      ],
    );
  }
}
