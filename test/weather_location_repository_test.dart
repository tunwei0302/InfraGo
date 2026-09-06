import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:infra_go/weather/weather_location_repository.dart';

Map<String, dynamic> _row({
  String id = 'loc-1',
  String label = 'Home',
  double latitude = 3.1390,
  double longitude = 101.6869,
  String createdAt = '2026-09-11T00:00:00.000Z',
}) => {
  'id': id,
  'label': label,
  'latitude': latitude,
  'longitude': longitude,
  'created_at': createdAt,
};

void main() {
  group('fetchAll', () {
    test('parses every saved location row into a model', () async {
      final repository = WeatherLocationRepository(
        null,
        selectAll: () async => [
          _row(id: 'loc-1', label: 'Home'),
          _row(id: 'loc-2', label: 'Campus', latitude: 3.2, longitude: 101.7),
        ],
      );
      final locations = await repository.fetchAll();
      expect(locations, hasLength(2));
      expect(locations[0].id, 'loc-1');
      expect(locations[0].label, 'Home');
      expect(locations[0].point, const LatLng(3.1390, 101.6869));
      expect(locations[1].label, 'Campus');
    });

    test('wraps a query failure in WeatherLocationException', () async {
      final repository = WeatherLocationRepository(
        null,
        selectAll: () async => throw Exception('network down'),
      );
      await expectLater(
        repository.fetchAll,
        throwsA(isA<WeatherLocationException>()),
      );
    });
  });

  group('create', () {
    test('refuses to save when nobody is signed in', () async {
      final repository = WeatherLocationRepository(
        null,
        currentUserId: () => null,
      );
      await expectLater(
        () => repository.create(
          label: 'Home',
          point: const LatLng(3.1390, 101.6869),
        ),
        throwsA(isA<WeatherLocationException>()),
      );
    });

    test('refuses an empty (or whitespace-only) name', () async {
      final repository = WeatherLocationRepository(
        null,
        currentUserId: () => 'user-1',
      );
      await expectLater(
        () => repository.create(
          label: '   ',
          point: const LatLng(3.1390, 101.6869),
        ),
        throwsA(isA<WeatherLocationException>()),
      );
    });

    test(
      'inserts exactly the row the table expects, trimmed and owned by the caller',
      () async {
        late Map<String, dynamic> insertedRow;
        final repository = WeatherLocationRepository(
          null,
          currentUserId: () => 'user-1',
          insert: (row) async {
            insertedRow = row;
            return _row(label: 'Home');
          },
        );
        final saved = await repository.create(
          label: '  Home  ',
          point: const LatLng(3.1390, 101.6869),
        );
        expect(insertedRow['user_id'], 'user-1');
        expect(insertedRow['label'], 'Home');
        expect(insertedRow['latitude'], 3.1390);
        expect(insertedRow['longitude'], 101.6869);
        expect(saved.label, 'Home');
      },
    );

    test('wraps a duplicate-name conflict from the unique index', () async {
      final repository = WeatherLocationRepository(
        null,
        currentUserId: () => 'user-1',
        insert: (row) async => throw Exception(
          'duplicate key value violates unique constraint '
          '"uq_weather_saved_locations_user_label"',
        ),
      );
      await expectLater(
        () => repository.create(
          label: 'Home',
          point: const LatLng(3.1390, 101.6869),
        ),
        throwsA(isA<WeatherLocationException>()),
      );
    });
  });

  group('update', () {
    test('refuses an empty name', () async {
      final repository = WeatherLocationRepository(null);
      await expectLater(
        () => repository.update(
          id: 'loc-1',
          label: '',
          point: const LatLng(3.1390, 101.6869),
        ),
        throwsA(isA<WeatherLocationException>()),
      );
    });

    test(
      'sends the trimmed label, new coordinates and a bumped updated_at',
      () async {
        late String updatedId;
        late Map<String, dynamic> patch;
        final repository = WeatherLocationRepository(
          null,
          update: (id, p) async {
            updatedId = id;
            patch = p;
            return _row(
              id: id,
              label: 'Office',
              latitude: 3.2,
              longitude: 101.7,
            );
          },
        );
        final updated = await repository.update(
          id: 'loc-1',
          label: '  Office  ',
          point: const LatLng(3.2, 101.7),
        );
        expect(updatedId, 'loc-1');
        expect(patch['label'], 'Office');
        expect(patch['latitude'], 3.2);
        expect(patch['longitude'], 101.7);
        expect(patch.containsKey('updated_at'), isTrue);
        expect(updated.label, 'Office');
        expect(updated.point, const LatLng(3.2, 101.7));
      },
    );

    test('wraps an update failure in WeatherLocationException', () async {
      final repository = WeatherLocationRepository(
        null,
        update: (id, p) async => throw Exception('not found'),
      );
      await expectLater(
        () => repository.update(
          id: 'missing',
          label: 'Home',
          point: const LatLng(3.1390, 101.6869),
        ),
        throwsA(isA<WeatherLocationException>()),
      );
    });
  });

  group('delete', () {
    test('deletes by id', () async {
      String? deletedId;
      final repository = WeatherLocationRepository(
        null,
        delete: (id) async => deletedId = id,
      );
      await repository.delete('loc-1');
      expect(deletedId, 'loc-1');
    });

    test('wraps a delete failure in WeatherLocationException', () async {
      final repository = WeatherLocationRepository(
        null,
        delete: (id) async => throw Exception('network down'),
      );
      await expectLater(
        () => repository.delete('loc-1'),
        throwsA(isA<WeatherLocationException>()),
      );
    });
  });
}
