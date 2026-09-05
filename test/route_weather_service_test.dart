import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'package:infra_go/weather/route_weather_service.dart';

http.Response _openMeteoResponse({
  double precipitation = 0,
  double windSpeed = 0,
  int weatherCode = 0,
  int statusCode = 200,
}) =>
    http.Response(
      jsonEncode({
        'current': {
          'precipitation': precipitation,
          'wind_speed_10m': windSpeed,
          'weather_code': weatherCode,
        },
      }),
      statusCode,
    );

void main() {
  const pickup = LatLng(3.1390, 101.6869);
  const destination = LatLng(3.2000, 101.7500);

  group('fetchSnapshot', () {
    test('parses precipitation, wind and condition from a live-shaped response', () async {
      final service = RouteWeatherService(
        httpGet: (uri) async {
          expect(uri.host, 'api.open-meteo.com');
          expect(uri.queryParameters['latitude'], '3.1390');
          expect(uri.queryParameters['longitude'], '101.6869');
          return _openMeteoResponse(
            precipitation: 12.5,
            windSpeed: 18.0,
            weatherCode: 61,
          );
        },
      );

      final snapshot = await service.fetchSnapshot(pickup);

      expect(snapshot.precipitationMmPerHour, 12.5);
      expect(snapshot.windSpeedKph, 18.0);
      expect(snapshot.condition, 'Rain');
    });

    test('throws WeatherFetchException on a non-2xx status', () async {
      final service = RouteWeatherService(
        httpGet: (uri) async => _openMeteoResponse(statusCode: 500),
      );

      expect(
        () => service.fetchSnapshot(pickup),
        throwsA(isA<WeatherFetchException>()),
      );
    });

    test('throws WeatherFetchException on malformed JSON', () async {
      final service = RouteWeatherService(
        httpGet: (uri) async => http.Response('not json', 200),
      );

      expect(
        () => service.fetchSnapshot(pickup),
        throwsA(isA<WeatherFetchException>()),
      );
    });

    test('throws WeatherFetchException when "current" is missing', () async {
      final service = RouteWeatherService(
        httpGet: (uri) async => http.Response(jsonEncode({}), 200),
      );

      expect(
        () => service.fetchSnapshot(pickup),
        throwsA(isA<WeatherFetchException>()),
      );
    });

    test('wraps a network failure in WeatherFetchException', () async {
      final service = RouteWeatherService(
        httpGet: (uri) async => throw Exception('socket closed'),
      );

      expect(
        () => service.fetchSnapshot(pickup),
        throwsA(isA<WeatherFetchException>()),
      );
    });
  });

  group('fetchRouteAdvisory', () {
    test('fetches both legs and classifies risk per leg', () async {
      final service = RouteWeatherService(
        httpGet: (uri) async {
          final lat = uri.queryParameters['latitude'];
          if (lat == '3.1390') {
            return _openMeteoResponse(precipitation: 1.0);
          }
          return _openMeteoResponse(precipitation: 25.0, weatherCode: 65);
        },
      );

      final advisory = await service.fetchRouteAdvisory(
        pickup: pickup,
        destination: destination,
        pickupLabel: 'NZ Grocer',
        destinationLabel: 'TARUMT ARENA',
      );

      expect(advisory.legs, hasLength(2));
      expect(advisory.legs[0].label, 'NZ Grocer');
      expect(advisory.legs[0].risk, RouteRiskLevel.none);
      expect(advisory.legs[1].label, 'TARUMT ARENA');
      expect(advisory.legs[1].risk, RouteRiskLevel.high);
      expect(advisory.overallRisk, RouteRiskLevel.high);
      expect(advisory.mostSevereLeg?.label, 'TARUMT ARENA');
    });

    test('propagates a WeatherFetchException if either leg fails', () async {
      final service = RouteWeatherService(
        httpGet: (uri) async => _openMeteoResponse(statusCode: 404),
      );

      expect(
        () => service.fetchRouteAdvisory(
          pickup: pickup,
          destination: destination,
        ),
        throwsA(isA<WeatherFetchException>()),
      );
    });
  });
}
