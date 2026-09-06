import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/20260911000000_f_weather_saved_locations.sql',
  ).readAsStringSync();

  test('schema enforces sane labels and real-world coordinates', () {
    expect(
      sql,
      contains(
        'label TEXT NOT NULL CHECK (char_length(trim(label)) BETWEEN 1 AND 40)',
      ),
    );
    expect(sql, contains('latitude DOUBLE PRECISION NOT NULL CHECK (latitude BETWEEN -90 AND 90)'));
    expect(
      sql,
      contains(
        'longitude DOUBLE PRECISION NOT NULL CHECK (longitude BETWEEN -180 AND 180)',
      ),
    );
  });

  test('a user cannot save two locations with the same name (case-insensitive)', () {
    expect(sql, contains('CREATE UNIQUE INDEX'));
    expect(sql, contains('uq_weather_saved_locations_user_label'));
    expect(sql, contains('ON weather_saved_locations(user_id, lower(label))'));
  });

  test('row level security is enabled with an owner-only policy for every CRUD operation', () {
    expect(sql, contains('ALTER TABLE weather_saved_locations ENABLE ROW LEVEL SECURITY'));

    for (final policy in [
      'weather_saved_locations_owner_select',
      'weather_saved_locations_owner_insert',
      'weather_saved_locations_owner_update',
      'weather_saved_locations_owner_delete',
    ]) {
      final start = sql.indexOf('CREATE POLICY $policy');
      expect(start, greaterThan(-1), reason: 'missing policy: $policy');
      final end = sql.indexOf(';', start);
      final policySql = sql.substring(start, end);
      expect(
        policySql,
        contains('user_id = auth.uid()'),
        reason: '$policy must be scoped to the owner',
      );
    }
  });

  test('update policy checks ownership on both the existing and the new row', () {
    final start = sql.indexOf('CREATE POLICY weather_saved_locations_owner_update');
    final end = sql.indexOf(';', start);
    final policySql = sql.substring(start, end);
    expect(policySql, contains('USING (user_id = auth.uid())'));
    expect(policySql, contains('WITH CHECK (user_id = auth.uid())'));
  });
}
