import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/location_search_service.dart';

void main() {
  test('parses, deduplicates, caches and biases Photon results', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      expect(request.url.host, 'photon.komoot.io');
      expect(request.url.path, '/api/');
      expect(request.url.queryParameters['q'], 'KLCC');
      expect(request.url.queryParameters['lat'], '3.139');
      expect(request.url.queryParameters['lon'], '101.6869');
      expect(request.headers['User-Agent'], contains('InfraGo-Mobile'));
      return http.Response('''
        {
          "features": [
            {
              "geometry": {"coordinates": [101.7132, 3.1579]},
              "properties": {
                "name": "Petronas Twin Towers",
                "street": "Jalan Ampang",
                "city": "Kuala Lumpur",
                "state": "Kuala Lumpur",
                "country": "Malaysia"
              }
            },
            {
              "geometry": {"coordinates": [101.7132, 3.1579]},
              "properties": {
                "name": "Petronas Twin Towers",
                "street": "Jalan Ampang",
                "city": "Kuala Lumpur",
                "state": "Kuala Lumpur",
                "country": "Malaysia"
              }
            }
          ]
        }
      ''', 200);
    });
    final service = PhotonLocationSearchService(client: client);

    final first = await service.search(
      'KLCC',
      near: const LatLng(3.139, 101.6869),
    );
    final cached = await service.search(
      'KLCC',
      near: const LatLng(3.139, 101.6869),
    );

    expect(first, hasLength(1));
    expect(first.single.name, 'Petronas Twin Towers');
    expect(first.single.point, const LatLng(3.1579, 101.7132));
    expect(first.single.bookingLabel, contains('Jalan Ampang'));
    expect(cached.single.name, 'Petronas Twin Towers');
    expect(requestCount, 1);
    service.close();
  });

  test(
    'returns no results for queries shorter than three characters',
    () async {
      final client = MockClient((_) async {
        fail('Short queries must not call the API.');
      });
      final service = PhotonLocationSearchService(client: client);

      expect(await service.search('KL'), isEmpty);
      service.close();
    },
  );
}
