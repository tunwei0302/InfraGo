import 'package:supabase_flutter/supabase_flutter.dart';

typedef DriverRatingInserter = Future<void> Function(Map<String, dynamic> row);

class DriverRatingException implements Exception {
  const DriverRatingException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DriverRatingRepository {
  DriverRatingRepository(
    SupabaseClient client, {
    DriverRatingInserter? insert,
    String? Function()? currentUserId,
  }) : _currentUserId = currentUserId ?? (() => client.auth.currentUser?.id),
       _insert = insert ?? ((row) => client.from('driver_ratings').insert(row));

  final String? Function() _currentUserId;
  final DriverRatingInserter _insert;

  Future<void> submitRating({
    required String rideId,
    required String driverId,
    required int score,
    List<String> tags = const [],
    String? comment,
    String? issueCategory,
  }) async {
    final riderId = _currentUserId();
    if (riderId == null) {
      throw const DriverRatingException('Sign in to rate your driver.');
    }
    try {
      await _insert({
        'ride_id': rideId,
        'rider_id': riderId,
        'driver_id': driverId,
        'score': score,
        'tags': tags,
        if (comment != null && comment.isNotEmpty) 'comment': comment,
        'issue_category': ?issueCategory,
      });
    } catch (error) {
      throw DriverRatingException('Could not submit your rating: $error');
    }
  }
}
