import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/osrm_routing_service.dart';

void main() {
  const origin = LatLng(3.139, 101.6869);
  const destination = LatLng(3.1579, 101.7132);
  final lineString = {
    'type': 'LineString',
    'coordinates': [
      [101.6869, 3.139],
      [101.69, 3.142],
      [101.7132, 3.1579],
    ],
  };

  test('single route parses distance, ETA and polyline geometry', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'router.project-osrm.org');
      expect(request.url.path, contains('/route/v1/driving/'));
      expect(request.headers['User-Agent'], contains('InfraGo-Mobile'));
      return http.Response(
        jsonEncode({
          'code': 'Ok',
          'routes': [
            {
              'geometry': lineString,
              'distance': 4250.5,
              'duration': 540.0,
              'legs': [
                {'distance': 4250.5, 'duration': 540.0, 'summary': ''},
              ],
            },
          ],
        }),
        200,
      );
    });
    final svc = OsrmRoutingService(client: client);

    final result = await svc.route(origin, destination);

    expect(result.distanceMeters, 4250.5);
    expect(result.durationSeconds, 540);
    expect(result.distanceLabel, '4.3 km');
    expect(result.etaLabel, '9 min');
    expect(result.points, hasLength(3));
    expect(result.points.first, origin);
    expect(result.points.last, destination);
    svc.close();
  });

  test('single route caches identical origin/destination', () async {
    var callCount = 0;
    final client = MockClient((request) async {
      callCount++;
      return http.Response(
        jsonEncode({
          'code': 'Ok',
          'routes': [
            {
              'geometry': lineString,
              'distance': 1000,
              'duration': 120,
              'legs': [
                {'distance': 1000, 'duration': 120, 'summary': ''},
              ],
            },
          ],
        }),
        200,
      );
    });
    final svc = OsrmRoutingService(client: client);

    final a = await svc.route(origin, destination);
    final b = await svc.route(origin, destination);
    expect(a.distanceMeters, b.distanceMeters);
    expect(callCount, 1);
    svc.close();
  });

  test('multi-stop route returns ordered legs and combined geometry', () async {
    final stops = [
      const LatLng(3.139, 101.6869),
      const LatLng(3.145, 101.7),
      const LatLng(3.1579, 101.7132),
    ];
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'code': 'Ok',
          'routes': [
            {
              'geometry': lineString,
              'distance': 5500,
              'duration': 720,
              'legs': [
                {'distance': 2200, 'duration': 280, 'summary': ''},
                {'distance': 3300, 'duration': 440, 'summary': ''},
              ],
            },
          ],
        }),
        200,
      );
    });
    final svc = OsrmRoutingService(client: client);

    final result = await svc.multiStopRoute(stops, preferredOrder: [0, 1, 2]);

    expect(result.stopOrder, [0, 1, 2]);
    expect(result.totalDistanceMeters, 5500);
    expect(result.totalDurationSeconds, 720);
    expect(result.legDistanceMeters, [2200, 3300]);
    expect(result.legDurationSeconds, [280, 440]);
    expect(result.points, hasLength(3));
    svc.close();
  });

  test(
    'routing errors surface as RoutingException, never fake success',
    () async {
      final client = MockClient((request) async {
        return http.Response(jsonEncode({'code': 'NoRoute'}), 200);
      });
      final svc = OsrmRoutingService(client: client);
      expect(
        () => svc.route(origin, destination),
        throwsA(isA<RoutingException>()),
      );
      svc.close();
    },
  );

  test('HTTP 500 converted to RoutingException', () async {
    final client = MockClient((request) async {
      return http.Response('gateway timeout', 504);
    });
    final svc = OsrmRoutingService(client: client);
    expect(
      () => svc.route(origin, destination),
      throwsA(isA<RoutingException>()),
    );
    svc.close();
  });

  test('malformed JSON converted to RoutingException', () async {
    final client = MockClient((request) async {
      return http.Response('not json at all', 200);
    });
    final svc = OsrmRoutingService(client: client);
    expect(
      () => svc.route(origin, destination),
      throwsA(isA<RoutingException>()),
    );
    svc.close();
  });

  test('bearing and direction helpers wrap correctly', () {
    final a = bearingBetween(const LatLng(0, 0), const LatLng(0.001, 0.001));
    final b = bearingBetween(const LatLng(0, 0), const LatLng(-0.001, -0.001));
    expect(a, inInclusiveRange(40, 50));
    expect(b, inInclusiveRange(220, 230));
    expect(directionDifferenceDegrees(350, 10), 20);
    expect(directionDifferenceDegrees(90, 95), 5);
    expect(directionDifferenceDegrees(90, 270), 180);
  });

  test('haversine helper approximates short distances in meters', () {
    const p1 = LatLng(3.139, 101.6869);
    const p2 = LatLng(3.1391, 101.6870);
    final d = haversineMeters(p1, p2);
    expect(d, inInclusiveRange(10, 20));
  });
}
