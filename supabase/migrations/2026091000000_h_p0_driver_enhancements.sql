CREATE OR REPLACE FUNCTION accept_available_ride(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_ride rides%ROWTYPE;
  v_vehicle driver_vehicles%ROWTYPE;
  v_presence driver_presence%ROWTYPE;
  v_summary JSONB;
  v_categories TEXT[];
BEGIN
  SELECT * INTO v_presence FROM driver_presence WHERE driver_id = v_driver_id FOR UPDATE;
  IF v_presence.driver_id IS NULL OR v_presence.is_online IS FALSE THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_not_online');
  END IF;
  IF v_presence.last_seen_at IS NULL OR
     v_presence.last_seen_at < now() - INTERVAL '30 seconds' THEN
    UPDATE driver_presence SET is_online = FALSE WHERE driver_id = v_driver_id;
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_not_online');
  END IF;
  IF v_presence.accepted_ride_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_has_active_ride');
  END IF;

  SELECT * INTO v_vehicle FROM driver_vehicles WHERE driver_id = v_driver_id;
  IF v_vehicle.driver_id IS NULL OR v_vehicle.approval_status != 'approved' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'vehicle_not_approved');
  END IF;

  v_categories := ARRAY['economy_4']::TEXT[];
  IF v_vehicle.vehicle_type IN ('suv', 'mpv') OR v_vehicle.passenger_capacity >= 6 THEN
    v_categories := array_append(v_categories, 'shared_economy');
  END IF;
  IF v_vehicle.passenger_capacity >= 6 THEN
    v_categories := array_append(v_categories, 'six_seater');
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_found');
  END IF;
  IF v_ride.driver_id IS NOT NULL OR v_ride.status != 'requested' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_available');
  END IF;
  IF NOT array_to_string(v_categories, ',') LIKE '%' || v_ride.service_type || '%' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'service_category_ineligible');
  END IF;
  IF v_vehicle.passenger_capacity < v_ride.passenger_count THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'vehicle_capacity_exceeded');
  END IF;
  IF v_ride.requested_at IS NOT NULL AND
     v_ride.requested_at < now() - INTERVAL '10 minutes' THEN
    UPDATE rides SET status = 'expired' WHERE id = v_ride.id;
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_expired');
  END IF;

  UPDATE rides SET
    driver_id = v_driver_id,
    driver_plate = v_vehicle.plate_number,
    status = 'driver_assigned',
    accepted_at = now(),
    free_cancel_until = now() + INTERVAL '3 minutes'
  WHERE id = v_ride.id;

  UPDATE driver_presence
    SET accepted_ride_id = v_ride.id, is_online = TRUE
    WHERE driver_id = v_driver_id;

  v_summary := jsonb_build_object(
    'success', TRUE,
    'ride_id', v_ride.id,
    'status', 'driver_assigned',
    'driver_name', (SELECT name FROM profiles WHERE id = v_driver_id),
    'driver_rating', (SELECT COALESCE(avg_driver_rating, 0) FROM driver_public_profiles dp WHERE dp.driver_id = v_driver_id),
    'driver_rating_count', (SELECT COALESCE(rating_count, 0) FROM driver_public_profiles dp WHERE dp.driver_id = v_driver_id),
    'vehicle_make', v_vehicle.make,
    'vehicle_model', v_vehicle.model,
    'vehicle_colour', v_vehicle.vehicle_colour,
    'vehicle_type', v_vehicle.vehicle_type,
    'vehicle_plate', v_vehicle.plate_number,
    'vehicle_capacity', v_vehicle.passenger_capacity,
    'accepted_at', now(),
    'free_cancel_until', now() + INTERVAL '3 minutes'
  );

  PERFORM pg_notify('ride:' || v_ride.id::TEXT, v_summary::TEXT);
  RETURN v_summary;
END;
$$;

CREATE OR REPLACE FUNCTION accept_carpool_group(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_group ride_groups%ROWTYPE;
  v_vehicle driver_vehicles%ROWTYPE;
  v_presence driver_presence%ROWTYPE;
  v_summary JSONB;
  v_categories TEXT[];
  v_rider_count INTEGER;
BEGIN
  SELECT * INTO v_presence FROM driver_presence WHERE driver_id = v_driver_id FOR UPDATE;
  IF v_presence.driver_id IS NULL OR v_presence.is_online IS FALSE THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_not_online');
  END IF;
  IF v_presence.last_seen_at IS NULL OR
     v_presence.last_seen_at < now() - INTERVAL '30 seconds' THEN
    UPDATE driver_presence SET is_online = FALSE WHERE driver_id = v_driver_id;
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_not_online');
  END IF;
  IF v_presence.accepted_ride_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_has_active_ride');
  END IF;

  SELECT * INTO v_vehicle FROM driver_vehicles WHERE driver_id = v_driver_id;
  IF v_vehicle.driver_id IS NULL OR v_vehicle.approval_status != 'approved' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'vehicle_not_approved');
  END IF;
  IF NOT (v_vehicle.vehicle_type IN ('suv', 'mpv') OR v_vehicle.passenger_capacity >= 6) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'service_category_ineligible');
  END IF;

  SELECT * INTO v_group FROM ride_groups WHERE id = p_group_id FOR UPDATE;
  IF v_group.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_found');
  END IF;
  IF v_group.driver_id IS NOT NULL OR v_group.status != 'ready_to_match' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_available');
  END IF;

  SELECT count(*) INTO v_rider_count
    FROM ride_group_members m WHERE m.group_id = v_group.id;
  IF v_rider_count < 2 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_needs_more_members');
  END IF;
  IF v_group.total_passengers > v_vehicle.passenger_capacity THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'vehicle_capacity_exceeded');
  END IF;

  UPDATE ride_groups SET
    driver_id = v_driver_id,
    status = 'driver_assigned'
  WHERE id = v_group.id;

  UPDATE rides SET
    driver_id = v_driver_id,
    driver_plate = v_vehicle.plate_number,
    status = 'driver_assigned',
    accepted_at = now(),
    free_cancel_until = now() + INTERVAL '3 minutes'
  WHERE group_id = v_group.id;

  UPDATE driver_presence
    SET accepted_group_id = v_group.id, is_online = TRUE
    WHERE driver_id = v_driver_id;

  v_summary := jsonb_build_object(
    'success', TRUE,
    'group_id', v_group.id,
    'status', 'driver_assigned',
    'driver_name', (SELECT name FROM profiles WHERE id = v_driver_id),
    'driver_rating', (SELECT COALESCE(avg_driver_rating, 0) FROM driver_public_profiles dp WHERE dp.driver_id = v_driver_id),
    'driver_rating_count', (SELECT COALESCE(rating_count, 0) FROM driver_public_profiles dp WHERE dp.driver_id = v_driver_id),
    'vehicle_make', v_vehicle.make,
    'vehicle_model', v_vehicle.model,
    'vehicle_colour', v_vehicle.vehicle_colour,
    'vehicle_type', v_vehicle.vehicle_type,
    'vehicle_plate', v_vehicle.plate_number,
    'vehicle_capacity', v_vehicle.passenger_capacity,
    'accepted_at', now(),
    'free_cancel_until', now() + INTERVAL '3 minutes'
  );

  PERFORM pg_notify('ride_group:' || v_group.id::TEXT, v_summary::TEXT);
  RETURN v_summary;
END;
$$;

REVOKE ALL ON FUNCTION accept_available_ride(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION accept_carpool_group(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION accept_available_ride(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION accept_carpool_group(UUID) TO authenticated;

ALTER TABLE ride_groups
  ADD COLUMN IF NOT EXISTS current_stop_idx INTEGER
    CHECK (current_stop_idx IS NULL OR current_stop_idx BETWEEN 0 AND 3);

ALTER TABLE ride_groups
  ADD COLUMN IF NOT EXISTS stop_arrived_at TIMESTAMPTZ[];

COMMENT ON COLUMN ride_groups.current_stop_idx IS
  '0..3 index into optimised_stop_order; NULL before first advance. '
  'Convention: stops 0 and 1 are pickups (P1, P2), stops 2 and 3 are dropoffs (D1, D2).';
COMMENT ON COLUMN ride_groups.stop_arrived_at IS
  'One arrival timestamp appended per successful advance_group_stop_pointer call.';

CREATE OR REPLACE FUNCTION advance_group_stop_pointer(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group ride_groups%ROWTYPE;
  v_next_idx INTEGER;
  v_is_pickup BOOLEAN;
BEGIN
  SELECT * INTO v_group FROM ride_groups WHERE id = p_group_id FOR UPDATE;
  IF v_group.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_found');
  END IF;
  IF v_group.driver_id IS NULL OR v_group.driver_id != auth.uid() THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_assigned_driver');
  END IF;
  IF v_group.status NOT IN ('driver_assigned', 'en_route') THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_in_progress');
  END IF;

  v_next_idx := COALESCE(v_group.current_stop_idx, -1) + 1;
  IF v_next_idx > 3 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'all_stops_done');
  END IF;

  IF v_group.status = 'driver_assigned' THEN
    UPDATE ride_groups SET status = 'en_route' WHERE id = v_group.id;
    UPDATE rides SET status = 'en_route' WHERE group_id = v_group.id;
  END IF;

  UPDATE ride_groups SET
    current_stop_idx = v_next_idx,
    stop_arrived_at = CASE
      WHEN stop_arrived_at IS NULL THEN ARRAY[now()]::TIMESTAMPTZ[]
      ELSE array_append(stop_arrived_at, now())
    END
  WHERE id = v_group.id;

  v_is_pickup := (v_next_idx < 2);

  RETURN jsonb_build_object(
    'success', TRUE,
    'current_stop_idx', v_next_idx,
    'is_pickup_stop', v_is_pickup,
    'remaining_stops', 3 - v_next_idx,
    'group_status', 'en_route'
  );
END;
$$;

REVOKE ALL ON FUNCTION advance_group_stop_pointer(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advance_group_stop_pointer(UUID) TO authenticated;

CREATE INDEX IF NOT EXISTS idx_rides_driver_id_status
  ON rides(driver_id, status) WHERE driver_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_rides_group_id
  ON rides(group_id) WHERE group_id IS NOT NULL;

ALTER TABLE rides ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rides_participant_select ON rides;
CREATE POLICY rides_participant_select ON rides FOR SELECT TO authenticated
USING (
  rider_id = auth.uid()
  OR driver_id = auth.uid()
  OR EXISTS (
    SELECT 1 FROM ride_group_members gm
    WHERE gm.ride_id = rides.id AND gm.rider_id = auth.uid()
  )
);

DROP POLICY IF EXISTS rides_rider_insert ON rides;
CREATE POLICY rides_rider_insert ON rides FOR INSERT TO authenticated
WITH CHECK (rider_id = auth.uid());

DROP POLICY IF EXISTS rides_rider_update_preassign ON rides;
CREATE POLICY rides_rider_update_preassign ON rides FOR UPDATE TO authenticated
USING (
  rider_id = auth.uid()
  AND driver_id IS NULL
  AND status NOT IN ('completed', 'cancelled', 'expired')
)
WITH CHECK (
  rider_id = auth.uid()
  AND driver_id IS NULL
  AND status NOT IN ('completed', 'cancelled', 'expired')
);
