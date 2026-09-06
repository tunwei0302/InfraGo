import 'package:supabase_flutter/supabase_flutter.dart';

typedef DriverRatingInserter = Future<void> Function(Map<String, dynamic> row);

typedef DriverRatingSelector =
    Future<List<Map<String, dynamic>>> Function(
      String from, {
      Map<String, dynamic>? eq,
      String? orderColumn,
      bool ascending,
      int? limit,
    });

typedef DriverRatingSummarySelector =
    Future<Map<String, dynamic>?> Function(String driverId);

class DriverRatingException implements Exception {
  const DriverRatingException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DriverRatingSummary {
  const DriverRatingSummary({
    required this.driverId,
    required this.ratingCount,
    required this.averageScore,
  });

  factory DriverRatingSummary.fromRow(Map<String, dynamic> row) {
    return DriverRatingSummary(
      driverId: row['driver_id'] as String,
      ratingCount: (row['rating_count'] as num).toInt(),
      averageScore: (row['average_score'] as num?)?.toDouble(),
    );
  }

  final String driverId;
  final int ratingCount;
  final double? averageScore;

  bool get hasRatings => ratingCount > 0;

  String get displayAverage {
    if (!hasRatings) return 'No ratings yet';
    return '${averageScore?.toStringAsFixed(1) ?? '-'} ($ratingCount review${ratingCount == 1 ? '' : 's'}';
  }
}

class DriverRatingDistribution {
  const DriverRatingDistribution({
    required this.stars1,
    required this.stars2,
    required this.stars3,
    required this.stars4,
    required this.stars5,
    required this.frequentPositiveTags,
    required this.lowRatingRate,
  });

  final int stars1;
  final int stars2;
  final int stars3;
  final int stars4;
  final int stars5;
  final List<TagFrequency> frequentPositiveTags;
  final double lowRatingRate;

  int get total => stars1 + stars2 + stars3 + stars4 + stars5;
}

class TagFrequency {
  const TagFrequency(this.tag, this.count);
  final String tag;
  final int count;
}

class DriverRatingFeedback {
  const DriverRatingFeedback({
    required this.score,
    required this.tags,
    required this.comment,
    required this.issueCategory,
    required this.createdAt,
  });

  final int score;
  final List<String> tags;
  final String? comment;
  final String? issueCategory;
  final DateTime createdAt;
}

class DriverRatingRepository {
  DriverRatingRepository(
    SupabaseClient client, {
    DriverRatingInserter? insert,
    String? Function()? currentUserId,
    DriverRatingSelector? selectRows,
    DriverRatingSummarySelector? selectSummary,
  }) : _currentUserId = currentUserId ?? (() => client.auth.currentUser?.id),
       _insert = insert ?? ((row) => client.from('driver_ratings').insert(row)),
       _selectRows =
           selectRows ??
           ((from, {eq, orderColumn, ascending = true, limit}) async {
             dynamic query = client.from(from).select();
             if (eq != null) {
               eq.forEach((key, value) => query = query.eq(key, value));
             }
             if (orderColumn != null) {
               query = query.order(orderColumn, ascending: ascending);
             }
             if (limit != null) {
               query = query.limit(limit);
             }
             final rows = await query;
             return List<Map<String, dynamic>>.from(rows);
           }),
       _selectSummary =
           selectSummary ??
           ((driverId) async {
             final rows = await client
                 .from('driver_rating_summary')
                 .select()
                 .eq('driver_id', driverId);
             final list = List<Map<String, dynamic>>.from(rows);
             return list.isEmpty ? null : list.first;
           });

  final String? Function() _currentUserId;
  final DriverRatingInserter _insert;
  final DriverRatingSelector _selectRows;
  final DriverRatingSummarySelector _selectSummary;

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
        if (issueCategory != null && issueCategory.isNotEmpty)
          'issue_category': issueCategory,
      });
    } catch (error) {
      throw DriverRatingException('Could not submit your rating: $error');
    }
  }

  Future<Map<String, dynamic>?> fetchMyRatingForRide(String rideId) async {
    final riderId = _currentUserId();
    if (riderId == null) return null;
    final rows = await _selectRows(
      'driver_ratings',
      eq: {'ride_id': rideId, 'rider_id': riderId},
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<DriverRatingSummary> fetchDriverSummary(String driverId) async {
    final row = await _selectSummary(driverId);
    if (row == null) {
      return DriverRatingSummary(
        driverId: driverId,
        ratingCount: 0,
        averageScore: null,
      );
    }
    return DriverRatingSummary.fromRow(row);
  }

  Future<DriverRatingDistribution> fetchDriverDistribution(
    String driverId, {
    List<String> positiveTags = const [
      'Clean vehicle',
      'Friendly',
      'Safe driving',
      'On time',
      'Great route',
    ],
  }) async {
    final allRows = await _selectRows(
      'driver_ratings',
      eq: {'driver_id': driverId},
    );
    var s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0;
    final tagCount = <String, int>{};
    for (final r in allRows) {
      final score = (r['score'] as num).toInt();
      switch (score) {
        case 1:
          s1++;
          break;
        case 2:
          s2++;
          break;
        case 3:
          s3++;
          break;
        case 4:
          s4++;
          break;
        case 5:
          s5++;
          break;
      }
      final rawTags = r['tags'] as List<dynamic>?;
      if (rawTags != null) {
        for (final t in rawTags) {
          final tag = t.toString();
          if (positiveTags.contains(tag)) {
            tagCount[tag] = (tagCount[tag] ?? 0) + 1;
          }
        }
      }
    }
    final total = s1 + s2 + s3 + s4 + s5;
    final lowRate = total == 0 ? 0.0 : (s1 + s2) / total;
    final freqTags =
        tagCount.entries.map((e) => TagFrequency(e.key, e.value)).toList()
          ..sort((a, b) => b.count.compareTo(a.count));
    return DriverRatingDistribution(
      stars1: s1,
      stars2: s2,
      stars3: s3,
      stars4: s4,
      stars5: s5,
      frequentPositiveTags: freqTags.take(5).toList(),
      lowRatingRate: lowRate,
    );
  }

  Future<List<DriverRatingFeedback>> fetchDriverFeedback(
    String driverId, {
    int limit = 20,
  }) async {
    final rows = await _selectRows(
      'driver_ratings',
      eq: {'driver_id': driverId},
      orderColumn: 'created_at',
      ascending: false,
      limit: limit,
    );
    return rows
        .map((r) {
          final rawTags = r['tags'] as List<dynamic>?;
          return DriverRatingFeedback(
            score: (r['score'] as num).toInt(),
            tags:
                rawTags?.map((e) => e.toString()).toList(growable: false) ??
                const [],
            comment: r['comment'] as String?,
            issueCategory: r['issue_category'] as String?,
            createdAt: DateTime.parse(r['created_at'] as String),
          );
        })
        .toList(growable: false);
  }
}
