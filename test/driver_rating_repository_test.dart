import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:infra_go/tey/driver_rating_repository.dart';

SupabaseClient _dummyClient() =>
    SupabaseClient('https://example.supabase.co', 'test-anon-key');

void main() {
  test('refuses to submit when nobody is signed in', () async {
    final repository = DriverRatingRepository(_dummyClient());
    await expectLater(
      () => repository.submitRating(rideId: 'ride-1', driverId: 'driver-1', score: 5),
      throwsA(isA<DriverRatingException>()),
    );
  });

  test('inserts exactly the row driver_ratings expects, with the rider id from auth', () async {
    late Map<String, dynamic> insertedRow;
    final repository = DriverRatingRepository(
      _dummyClient(),
      currentUserId: () => 'rider-1',
      insert: (row) async => insertedRow = row,
    );
    await repository.submitRating(
      rideId: 'ride-1',
      driverId: 'driver-1',
      score: 4,
      tags: const ['Friendly', 'On time'],
      comment: 'Great trip',
    );
    expect(insertedRow['ride_id'], 'ride-1');
    expect(insertedRow['rider_id'], 'rider-1');
    expect(insertedRow['driver_id'], 'driver-1');
    expect(insertedRow['score'], 4);
    expect(insertedRow['tags'], ['Friendly', 'On time']);
    expect(insertedRow['comment'], 'Great trip');
    expect(insertedRow.containsKey('issue_category'), isFalse);
  });

  test('omits comment and issue_category when not provided', () async {
    late Map<String, dynamic> insertedRow;
    final repository = DriverRatingRepository(
      _dummyClient(),
      currentUserId: () => 'rider-1',
      insert: (row) async => insertedRow = row,
    );
    await repository.submitRating(rideId: 'ride-1', driverId: 'driver-1', score: 5);
    expect(insertedRow.containsKey('comment'), isFalse);
    expect(insertedRow.containsKey('issue_category'), isFalse);
  });

  test('includes issue_category for a low score when provided', () async {
    late Map<String, dynamic> insertedRow;
    final repository = DriverRatingRepository(
      _dummyClient(),
      currentUserId: () => 'rider-1',
      insert: (row) async => insertedRow = row,
    );
    await repository.submitRating(
      rideId: 'ride-1',
      driverId: 'driver-1',
      score: 1,
      issueCategory: 'Safety',
    );
    expect(insertedRow['issue_category'], 'Safety');
  });

  test('a failed insert (e.g. duplicate rating) is wrapped in DriverRatingException', () async {
    final repository = DriverRatingRepository(
      _dummyClient(),
      currentUserId: () => 'rider-1',
      insert: (row) async => throw Exception('duplicate key value violates unique constraint'),
    );
    await expectLater(
      () => repository.submitRating(rideId: 'ride-1', driverId: 'driver-1', score: 3),
      throwsA(isA<DriverRatingException>()),
    );
  });
}
