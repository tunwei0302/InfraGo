import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/kueh/location_search_service.dart';

void main() {
  group('Photon stale response handling', () {
    test('newer request id wins over slower older responses', () async {
      final completer1 = Completer<http.Response>();
      final completer2 = Completer<http.Response>();
      var callIndex = 0;

      final client = MockClient((request) async {
        callIndex++;
        if (callIndex == 1) return completer1.future;
        return completer2.future;
      });
      final service = PhotonLocationSearchService(client: client);

      final near = const LatLng(3.139, 101.6869);
      final slowResult = service.search('KLCC park', near: near);
      final fastResult = service.search('KLCC', near: near);

      completer2.complete(
        http.Response(
          jsonEncode({
            'features': [
              {
                'geometry': {
                  'coordinates': [101.7132, 3.1579],
                },
                'properties': {'name': 'Petronas Twin Towers', 'city': 'KL'},
              },
            ],
          }),
          200,
        ),
      );
      final fast = await fastResult;
      expect(fast.single.name, 'Petronas Twin Towers');

      completer1.complete(
        http.Response(
          jsonEncode({
            'features': [
              {
                'geometry': {
                  'coordinates': [101.7, 3.15],
                },
                'properties': {'name': 'KLCC Park Lake', 'city': 'KL'},
              },
            ],
          }),
          200,
        ),
      );
      final slow = await slowResult;

      expect(slow.single.name, 'KLCC Park Lake');
      service.close();
    });

    test(
      'reverse returns null safely when network returns empty feature list',
      () async {
        final client = MockClient((request) async {
          expect(request.url.path, contains('/reverse'));
          return http.Response(jsonEncode({'features': []}), 200);
        });
        final service = PhotonLocationSearchService(client: client);
        final result = await service.reverse(const LatLng(3.139, 101.6869));
        expect(result, isNull);
        service.close();
      },
    );
  });
}
