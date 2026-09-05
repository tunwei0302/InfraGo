import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/20260906001000_k_shared_candidates_and_chat_photos.sql',
  ).readAsStringSync();
  final service = File(
    'lib/kueh/supabase_carpool_service.dart',
  ).readAsStringSync();
  final planner = File(
    'lib/kueh/trip_planner_map_screen.dart',
  ).readAsStringSync();

  test('shared candidates use an authenticated RLS-safe RPC', () {
    expect(sql, contains('FUNCTION list_shared_ride_candidates'));
    expect(sql, contains('SECURITY DEFINER'));
    expect(sql, contains('rider_id = auth.uid()'));
    expect(sql, contains("'rider_id', 'anonymous-candidate'"));
    expect(sql, contains('r.rider_id != auth.uid()'));
    expect(sql, contains('GRANT EXECUTE'));
    expect(service, contains("client.rpc("));
    expect(service, contains("'list_shared_ride_candidates'"));
  });

  test('shared matching retries during a bounded waiting window', () {
    expect(planner, contains('kSharedMatchWindow = Duration(seconds: 60)'));
    expect(
      planner,
      contains('kSharedMatchRetryInterval = Duration(seconds: 5)'),
    );
    expect(planner, contains('Timer.periodic(kSharedMatchRetryInterval'));
  });

  test('pickup landmark becomes one private chat image message', () {
    expect(sql, contains('ADD COLUMN IF NOT EXISTS image_path TEXT'));
    expect(sql, contains('publish_pickup_landmark_to_chat'));
    expect(sql, contains("'Pickup landmark photo'"));
    expect(sql, contains('NEW.pickup_landmark_path'));
    expect(sql, contains('idx_messages_one_pickup_photo_per_ride'));
    expect(sql, contains("LIKE NEW.rider_id::text || '/' || NEW.id::text"));
  });
}
