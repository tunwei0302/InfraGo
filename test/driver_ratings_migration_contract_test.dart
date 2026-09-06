import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/20260901000000_t_driver_ratings.sql',
  ).readAsStringSync();

  test('one rating per ride is enforced at the schema level', () {
    expect(sql, contains('ride_id UUID NOT NULL UNIQUE'));
    expect(
      sql,
      contains('score INTEGER NOT NULL CHECK (score BETWEEN 1 AND 5)'),
    );
    expect(sql, contains('char_length(comment) <= 300'));
  });

  test(
    'only the completed ride\'s own rider can insert a rating for the assigned driver',
    () {
      final policyStart = sql.indexOf(
        'CREATE POLICY driver_ratings_rider_insert',
      );
      final policyEnd = sql.length;
      final policySql = sql.substring(policyStart, policyEnd);
      expect(policySql, contains('rider_id = auth.uid()'));
      expect(policySql, contains('r.rider_id = auth.uid()'));
      expect(policySql, contains('r.driver_id = driver_ratings.driver_id'));
      expect(policySql, contains("r.status = 'completed'"));
    },
  );

  test(
    'drivers can only ever see aggregated feedback, never rider identity',
    () {
      expect(
        sql,
        isNot(contains('driver_ratings FOR SELECT USING (driver_id')),
      );
      expect(sql, contains('driver_ratings_rider_read'));
      expect(sql, contains('rider_id = auth.uid()'));
      expect(sql, contains('CREATE OR REPLACE VIEW driver_rating_summary'));
      final viewStart = sql.indexOf(
        'CREATE OR REPLACE VIEW driver_rating_summary',
      );
      final viewEnd = sql.indexOf(
        'GRANT SELECT ON driver_rating_summary',
        viewStart,
      );
      final viewSql = sql.substring(viewStart, viewEnd);
      expect(viewSql, isNot(contains('rider_id')));
      expect(viewSql, isNot(contains('comment')));
      expect(viewSql, contains('AVG(score)'));
    },
  );

  test(
    'ratings are never client-writable except through the guarded insert policy',
    () {
      expect(sql, isNot(contains('driver_ratings FOR UPDATE')));
      expect(sql, isNot(contains('driver_ratings FOR DELETE')));
    },
  );
}
