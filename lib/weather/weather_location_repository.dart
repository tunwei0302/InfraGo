import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class WeatherLocationException implements Exception {
  const WeatherLocationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class WeatherSavedLocation {
  const WeatherSavedLocation({
    required this.id,
    required this.label,
    required this.point,
    required this.createdAt,
  });

  factory WeatherSavedLocation.fromRow(Map<String, dynamic> row) {
    return WeatherSavedLocation(
      id: row['id'] as String,
      label: row['label'] as String,
      point: LatLng(
        (row['latitude'] as num).toDouble(),
        (row['longitude'] as num).toDouble(),
      ),
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  final String id;
  final String label;
  final LatLng point;
  final DateTime createdAt;
}

typedef WeatherLocationSelector = Future<List<Map<String, dynamic>>>
    Function();
typedef WeatherLocationInserter = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> row,
);
typedef WeatherLocationUpdater = Future<Map<String, dynamic>> Function(
  String id,
  Map<String, dynamic> patch,
);
typedef WeatherLocationDeleter = Future<void> Function(String id);

/// Owner-only CRUD over `weather_saved_locations`. Every write is scoped to
/// the signed-in user both here and by the table's RLS policies — losing
/// either half would either leak location names across accounts or let the
/// UI silently no-op for a signed-out user.
class WeatherLocationRepository {
  /// [client] is only touched by the default implementations below, so it
  /// can be omitted (null) when every operation is overridden — e.g. in
  /// widget tests, where constructing a real [SupabaseClient] would spin up
  /// a GoTrue auto-refresh timer that outlives the test.
  WeatherLocationRepository(
    SupabaseClient? client, {
    String? Function()? currentUserId,
    WeatherLocationSelector? selectAll,
    WeatherLocationInserter? insert,
    WeatherLocationUpdater? update,
    WeatherLocationDeleter? delete,
  })  : _currentUserId = currentUserId ?? (() => client!.auth.currentUser?.id),
        _selectAll = selectAll ??
            (() async {
              final rows = await client!
                  .from('weather_saved_locations')
                  .select()
                  .order('created_at');
              return List<Map<String, dynamic>>.from(rows);
            }),
        _insert = insert ??
            ((row) async {
              final result = await client!
                  .from('weather_saved_locations')
                  .insert(row)
                  .select()
                  .single();
              return Map<String, dynamic>.from(result);
            }),
        _update = update ??
            ((id, patch) async {
              final result = await client!
                  .from('weather_saved_locations')
                  .update(patch)
                  .eq('id', id)
                  .select()
                  .single();
              return Map<String, dynamic>.from(result);
            }),
        _delete = delete ??
            ((id) async {
              await client!
                  .from('weather_saved_locations')
                  .delete()
                  .eq('id', id);
            });

  final String? Function() _currentUserId;
  final WeatherLocationSelector _selectAll;
  final WeatherLocationInserter _insert;
  final WeatherLocationUpdater _update;
  final WeatherLocationDeleter _delete;

  Future<List<WeatherSavedLocation>> fetchAll() async {
    try {
      final rows = await _selectAll();
      return rows.map(WeatherSavedLocation.fromRow).toList(growable: false);
    } catch (error) {
      throw WeatherLocationException(
        'Could not load your saved locations: $error',
      );
    }
  }

  Future<WeatherSavedLocation> create({
    required String label,
    required LatLng point,
  }) async {
    final userId = _currentUserId();
    if (userId == null) {
      throw const WeatherLocationException('Sign in to save locations.');
    }
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      throw const WeatherLocationException('Give this location a name.');
    }
    try {
      final row = await _insert({
        'user_id': userId,
        'label': trimmed,
        'latitude': point.latitude,
        'longitude': point.longitude,
      });
      return WeatherSavedLocation.fromRow(row);
    } on WeatherLocationException {
      rethrow;
    } catch (error) {
      throw WeatherLocationException('Could not save this location: $error');
    }
  }

  Future<WeatherSavedLocation> update({
    required String id,
    required String label,
    required LatLng point,
  }) async {
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      throw const WeatherLocationException('Give this location a name.');
    }
    try {
      final row = await _update(id, {
        'label': trimmed,
        'latitude': point.latitude,
        'longitude': point.longitude,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      return WeatherSavedLocation.fromRow(row);
    } on WeatherLocationException {
      rethrow;
    } catch (error) {
      throw WeatherLocationException(
        'Could not update this location: $error',
      );
    }
  }

  Future<void> delete(String id) async {
    try {
      await _delete(id);
    } catch (error) {
      throw WeatherLocationException(
        'Could not delete this location: $error',
      );
    }
  }
}
