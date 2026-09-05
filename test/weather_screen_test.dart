import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'package:infra_go/weather/route_weather_service.dart';
import 'package:infra_go/weather/weather_location_repository.dart';
import 'package:infra_go/weather/weather_screen.dart';

Future<(LatLng, String)> _fakeResolveLocation() async =>
    (kWeatherDefaultReferencePoint, kWeatherDefaultReferenceLabel);

/// Widget tests never call `Supabase.initialize`, and constructing a real
/// `SupabaseClient` spins up a GoTrue auto-refresh timer that would outlive
/// the test — so this stubs every operation and passes no client at all.
WeatherLocationRepository _fakeLocationRepository() =>
    WeatherLocationRepository(null, selectAll: () async => const []);

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
  testWidgets(
    'shows current conditions and a risk-free banner for calm weather',
    (tester) async {
      final service = RouteWeatherService(
        httpGet: (uri) async => _openMeteoResponse(windSpeed: 5.0),
      );

      await tester.pumpWidget(
        MaterialApp(home: WeatherScreen(
          service: service,
          resolveLocation: _fakeResolveLocation,
          locationRepository: _fakeLocationRepository(),
        )),
      );
      await tester.pumpAndSettle();

      expect(find.text('Clear'), findsOneWidget);
      expect(find.text('0.0 mm/h'), findsOneWidget);
      expect(find.text('5 km/h'), findsOneWidget);
      expect(find.textContaining('No significant weather risk'), findsOneWidget);
    },
  );

  testWidgets('shows a high-risk banner for heavy rain', (tester) async {
    final service = RouteWeatherService(
      httpGet: (uri) async =>
          _openMeteoResponse(precipitation: 25.0, weatherCode: 65),
    );

    await tester.pumpWidget(
      MaterialApp(home: WeatherScreen(
          service: service,
          resolveLocation: _fakeResolveLocation,
          locationRepository: _fakeLocationRepository(),
        )),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Heavy rain expected'), findsOneWidget);
    expect(find.textContaining('flooding possible'), findsOneWidget);
  });

  testWidgets('shows a retry button when the fetch fails', (tester) async {
    final service = RouteWeatherService(
      httpGet: (uri) async => _openMeteoResponse(statusCode: 500),
    );

    await tester.pumpWidget(
      MaterialApp(home: WeatherScreen(
          service: service,
          resolveLocation: _fakeResolveLocation,
          locationRepository: _fakeLocationRepository(),
        )),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not load weather'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Retry'), findsOneWidget);
  });
}
