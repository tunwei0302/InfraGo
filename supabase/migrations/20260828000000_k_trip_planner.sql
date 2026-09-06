ALTER TABLE rides ADD COLUMN IF NOT EXISTS service_type TEXT NOT NULL DEFAULT 'economy_4';
ALTER TABLE rides ADD COLUMN IF NOT EXISTS passenger_count INTEGER NOT NULL DEFAULT 1;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS departure_time TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE rides ADD COLUMN IF NOT EXISTS pickup_latitude DOUBLE PRECISION;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS pickup_longitude DOUBLE PRECISION;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS destination_latitude DOUBLE PRECISION;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS destination_longitude DOUBLE PRECISION;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS route_distance_meters DOUBLE PRECISION;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS route_duration_seconds DOUBLE PRECISION;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS pickup_note TEXT;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS transit_stop_id TEXT;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS transit_stop_name TEXT;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS estimated_solo_fare NUMERIC(10, 2);
ALTER TABLE rides ADD COLUMN IF NOT EXISTS estimated_shared_fare NUMERIC(10, 2);
ALTER TABLE rides ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS cancellation_reason TEXT;

UPDATE rides
SET service_type = CASE service_type
  WHEN 'standard' THEN 'economy_4'
  WHEN 'economy' THEN 'economy_4'
  WHEN 'suv' THEN 'six_seater'
  ELSE service_type
END
WHERE service_type IN ('standard', 'economy', 'suv');

DO $$ BEGIN
  ALTER TABLE rides ADD CONSTRAINT rides_service_type_check
    CHECK (service_type IN ('economy_4', 'six_seater', 'shared_economy'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE rides ADD CONSTRAINT rides_passenger_count_check
    CHECK (
      passenger_count BETWEEN 1 AND 6
      AND (service_type != 'shared_economy' OR passenger_count <= 2)
      AND (service_type != 'economy_4' OR passenger_count <= 4)
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS ride_groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  status TEXT NOT NULL DEFAULT 'matched'
    CHECK (status IN ('searching', 'matched', 'driver_assigned', 'en_route', 'completed', 'cancelled')),
  total_passengers INTEGER NOT NULL CHECK (total_passengers BETWEEN 2 AND 4),
  match_score INTEGER NOT NULL CHECK (match_score BETWEEN 60 AND 100),
  match_reasons TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  optimised_stop_order INTEGER[] NOT NULL,
  route_distance_meters DOUBLE PRECISION NOT NULL,
  route_duration_seconds DOUBLE PRECISION NOT NULL,
  vehicle_km_avoided DOUBLE PRECISION,
  driver_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  matched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ
);

ALTER TABLE rides ADD COLUMN IF NOT EXISTS group_id UUID REFERENCES ride_groups(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS ride_group_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES ride_groups(id) ON DELETE CASCADE,
  ride_id UUID NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  rider_id UUID NOT NULL,
  stop_index_pickup INTEGER NOT NULL CHECK (stop_index_pickup BETWEEN 0 AND 3),
  stop_index_destination INTEGER NOT NULL CHECK (stop_index_destination BETWEEN 0 AND 3),
  detour_percent DOUBLE PRECISION NOT NULL CHECK (detour_percent BETWEEN 0 AND 25),
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (group_id, ride_id),
  UNIQUE (ride_id),
  CHECK (stop_index_pickup < stop_index_destination)
);

CREATE INDEX IF NOT EXISTS idx_rides_shared_candidates
  ON rides(service_type, status, departure_time);
CREATE INDEX IF NOT EXISTS idx_ride_group_members_group ON ride_group_members(group_id);

CREATE TABLE IF NOT EXISTS driver_presence (
  driver_id UUID PRIMARY KEY,
  anonymised_id TEXT NOT NULL UNIQUE,
  coarse_lat DOUBLE PRECISION NOT NULL,
  coarse_lng DOUBLE PRECISION NOT NULL,
  vehicle_categories TEXT[] NOT NULL DEFAULT ARRAY['economy_4']::TEXT[],
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_online BOOLEAN NOT NULL DEFAULT FALSE,
  is_assigned BOOLEAN NOT NULL DEFAULT FALSE,
  heading DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS assigned_driver_location (
  ride_id UUID PRIMARY KEY REFERENCES rides(id) ON DELETE CASCADE,
  driver_id UUID NOT NULL,
  exact_lat DOUBLE PRECISION NOT NULL,
  exact_lng DOUBLE PRECISION NOT NULL,
  vehicle_plate TEXT NOT NULL,
  heading DOUBLE PRECISION,
  seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS transit_stops (
  stop_id TEXT PRIMARY KEY,
  stop_code TEXT,
  stop_name TEXT NOT NULL,
  route_name TEXT,
  latitude DOUBLE PRECISION NOT NULL,
  longitude DOUBLE PRECISION NOT NULL,
  source TEXT NOT NULL DEFAULT 'data.gov.my GTFS Static',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE VIEW nearby_driver_presence
WITH (security_barrier = true)
AS
SELECT anonymised_id, coarse_lat, coarse_lng, vehicle_categories,
       last_seen_at, is_online, is_assigned, heading
FROM driver_presence
WHERE is_online = TRUE
  AND is_assigned = FALSE
  AND last_seen_at >= now() - INTERVAL '60 seconds';

REVOKE ALL ON driver_presence FROM anon, authenticated;
GRANT SELECT ON nearby_driver_presence TO authenticated;

CREATE OR REPLACE FUNCTION upsert_my_driver_presence(
  p_coarse_lat DOUBLE PRECISION,
  p_coarse_lng DOUBLE PRECISION,
  p_vehicle_categories TEXT[],
  p_is_online BOOLEAN,
  p_is_assigned BOOLEAN,
  p_heading DOUBLE PRECISION DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;
  INSERT INTO driver_presence (
    driver_id, anonymised_id, coarse_lat, coarse_lng, vehicle_categories,
    is_online, is_assigned, heading, last_seen_at
  ) VALUES (
    auth.uid(),
    'V-' || upper(substr(md5(auth.uid()::TEXT || current_date::TEXT), 1, 8)),
    p_coarse_lat, p_coarse_lng,
    p_vehicle_categories, p_is_online, p_is_assigned, p_heading, now()
  )
  ON CONFLICT (driver_id) DO UPDATE SET
    anonymised_id = EXCLUDED.anonymised_id,
    coarse_lat = EXCLUDED.coarse_lat,
    coarse_lng = EXCLUDED.coarse_lng,
    vehicle_categories = EXCLUDED.vehicle_categories,
    is_online = EXCLUDED.is_online,
    is_assigned = EXCLUDED.is_assigned,
    heading = EXCLUDED.heading,
    last_seen_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION create_carpool_match(
  p_ride_a UUID,
  p_ride_b UUID,
  p_match_score INTEGER,
  p_match_reasons TEXT[],
  p_stop_order INTEGER[],
  p_detour_a DOUBLE PRECISION,
  p_detour_b DOUBLE PRECISION,
  p_route_distance_meters DOUBLE PRECISION,
  p_route_duration_seconds DOUBLE PRECISION,
  p_vehicle_km_avoided DOUBLE PRECISION
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a rides%ROWTYPE;
  v_b rides%ROWTYPE;
  v_group_id UUID;
  v_pickup_a INTEGER;
  v_drop_a INTEGER;
  v_pickup_b INTEGER;
  v_drop_b INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  IF p_ride_a = p_ride_b OR p_match_score < 60 OR p_match_score > 100 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_match');
  END IF;
  IF p_detour_a < 0 OR p_detour_a > 25 OR p_detour_b < 0 OR p_detour_b > 25 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'detour_limit');
  END IF;
  IF array_length(p_stop_order, 1) != 4 OR
     (SELECT COUNT(DISTINCT value) FROM unnest(p_stop_order) value) != 4 OR
     NOT (p_stop_order @> ARRAY[0,1,2,3]) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_stop_order');
  END IF;

  SELECT * INTO v_a FROM rides WHERE id = p_ride_a FOR UPDATE;
  SELECT * INTO v_b FROM rides WHERE id = p_ride_b FOR UPDATE;
  IF v_a.id IS NULL OR v_b.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_found');
  END IF;
  IF auth.uid() NOT IN (v_a.rider_id, v_b.rider_id) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_a_ride_owner');
  END IF;
  IF v_a.rider_id = v_b.rider_id THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'same_rider');
  END IF;
  IF v_a.service_type != 'shared_economy' OR v_b.service_type != 'shared_economy'
     OR v_a.status NOT IN ('waiting_match', 'requested')
     OR v_b.status NOT IN ('waiting_match', 'requested')
     OR v_a.group_id IS NOT NULL OR v_b.group_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_available');
  END IF;
  IF v_a.passenger_count + v_b.passenger_count > 4 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'capacity_exceeded');
  END IF;
  IF abs(extract(epoch FROM (v_a.departure_time - v_b.departure_time))) > 900 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'departure_gap');
  END IF;

  v_pickup_a := array_position(p_stop_order, 0) - 1;
  v_pickup_b := array_position(p_stop_order, 1) - 1;
  v_drop_a := array_position(p_stop_order, 2) - 1;
  v_drop_b := array_position(p_stop_order, 3) - 1;
  IF v_pickup_a >= v_drop_a OR v_pickup_b >= v_drop_b THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'pickup_after_dropoff');
  END IF;

  INSERT INTO ride_groups (
    status, total_passengers, match_score, match_reasons,
    optimised_stop_order, route_distance_meters, route_duration_seconds,
    vehicle_km_avoided
  ) VALUES (
    'matched', v_a.passenger_count + v_b.passenger_count, p_match_score,
    p_match_reasons, p_stop_order, p_route_distance_meters,
    p_route_duration_seconds, GREATEST(0, p_vehicle_km_avoided)
  ) RETURNING id INTO v_group_id;

  INSERT INTO ride_group_members (
    group_id, ride_id, rider_id, stop_index_pickup,
    stop_index_destination, detour_percent
  ) VALUES
    (v_group_id, v_a.id, v_a.rider_id, v_pickup_a, v_drop_a, p_detour_a),
    (v_group_id, v_b.id, v_b.rider_id, v_pickup_b, v_drop_b, p_detour_b);

  UPDATE rides SET group_id = v_group_id, status = 'matched'
  WHERE id IN (v_a.id, v_b.id);
  RETURN jsonb_build_object('success', TRUE, 'group_id', v_group_id);
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('success', FALSE, 'reason', 'concurrent_match_lost');
END;
$$;

CREATE OR REPLACE FUNCTION cancel_carpool_group_membership(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_id UUID;
BEGIN
  SELECT group_id INTO v_group_id FROM rides
  WHERE id = p_ride_id AND rider_id = auth.uid() FOR UPDATE;
  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_owned_or_not_grouped');
  END IF;
  UPDATE rides SET group_id = NULL, status = 'cancelled', cancelled_at = now()
  WHERE id = p_ride_id AND rider_id = auth.uid();
  UPDATE rides SET
    group_id = NULL,
    status = CASE WHEN status = 'matched' THEN 'waiting_match' ELSE status END
  WHERE group_id = v_group_id AND id != p_ride_id;
  DELETE FROM ride_group_members WHERE group_id = v_group_id;
  UPDATE ride_groups SET status = 'cancelled', cancelled_at = now()
  WHERE id = v_group_id;
  RETURN jsonb_build_object('success', TRUE, 'group_id', v_group_id);
END;
$$;

REVOKE ALL ON FUNCTION upsert_my_driver_presence(
  DOUBLE PRECISION, DOUBLE PRECISION, TEXT[], BOOLEAN, BOOLEAN,
  DOUBLE PRECISION
) FROM PUBLIC;
REVOKE ALL ON FUNCTION create_carpool_match(
  UUID, UUID, INTEGER, TEXT[], INTEGER[], DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION
) FROM PUBLIC;

CREATE OR REPLACE FUNCTION accept_carpool_group(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group ride_groups%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  SELECT * INTO v_group FROM ride_groups WHERE id = p_group_id FOR UPDATE;
  IF v_group.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_found');
  END IF;
  IF v_group.status != 'matched' OR v_group.driver_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_available');
  END IF;
  IF EXISTS (
    SELECT 1 FROM ride_group_members
    WHERE group_id = v_group.id AND rider_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'rider_cannot_accept_own_group');
  END IF;

  UPDATE ride_groups
  SET driver_id = auth.uid(), status = 'driver_assigned'
  WHERE id = v_group.id;

  UPDATE rides
  SET driver_id = auth.uid(), status = 'driver_assigned'
  WHERE id IN (
    SELECT ride_id FROM ride_group_members WHERE group_id = v_group.id
  );

  RETURN jsonb_build_object('success', TRUE, 'group_id', v_group.id);
END;
$$;

REVOKE ALL ON FUNCTION cancel_carpool_group_membership(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_my_driver_presence(
  DOUBLE PRECISION, DOUBLE PRECISION, TEXT[], BOOLEAN, BOOLEAN,
  DOUBLE PRECISION
) TO authenticated;
GRANT EXECUTE ON FUNCTION create_carpool_match(
  UUID, UUID, INTEGER, TEXT[], INTEGER[], DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION
) TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_carpool_group_membership(UUID) TO authenticated;
REVOKE ALL ON FUNCTION accept_carpool_group(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION accept_carpool_group(UUID) TO authenticated;

ALTER TABLE ride_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE ride_group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE assigned_driver_location ENABLE ROW LEVEL SECURITY;
ALTER TABLE transit_stops ENABLE ROW LEVEL SECURITY;

ALTER TABLE driver_presence ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ride_groups_participant_read ON ride_groups;
CREATE POLICY ride_groups_participant_read ON ride_groups FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM ride_group_members gm
    JOIN rides r ON r.id = gm.ride_id
    WHERE gm.group_id = ride_groups.id
      AND (r.rider_id = auth.uid() OR r.driver_id = auth.uid())
  )
);

DROP POLICY IF EXISTS ride_group_members_participant_read ON ride_group_members;
CREATE POLICY ride_group_members_participant_read ON ride_group_members FOR SELECT USING (
  rider_id = auth.uid() OR EXISTS (
    SELECT 1 FROM rides assigned
    WHERE assigned.id = ride_group_members.ride_id
      AND assigned.driver_id = auth.uid()
  )
);

DROP POLICY IF EXISTS assigned_location_participant_read ON assigned_driver_location;
CREATE POLICY assigned_location_participant_read ON assigned_driver_location FOR SELECT USING (
  driver_id = auth.uid() OR EXISTS (
    SELECT 1 FROM rides r
    WHERE r.id = assigned_driver_location.ride_id
      AND r.rider_id = auth.uid()
      AND r.driver_id = assigned_driver_location.driver_id
  )
);

DROP POLICY IF EXISTS transit_stops_authenticated_read ON transit_stops;
CREATE POLICY transit_stops_authenticated_read ON transit_stops FOR SELECT
USING (auth.uid() IS NOT NULL);

ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS messages_trip_participant_read ON messages;
CREATE POLICY messages_trip_participant_read ON messages FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM rides r
    WHERE r.id = messages.ride_id
      AND (r.rider_id = auth.uid() OR r.driver_id = auth.uid())
  )
);

DROP POLICY IF EXISTS messages_trip_participant_insert ON messages;
CREATE POLICY messages_trip_participant_insert ON messages FOR INSERT WITH CHECK (
  sender_id = auth.uid() AND EXISTS (
    SELECT 1 FROM rides r
    WHERE r.id = messages.ride_id
      AND (r.rider_id = auth.uid() OR r.driver_id = auth.uid())
      AND r.driver_id IS NOT NULL
      AND r.status IN ('driver_assigned', 'en_route')
  )
);
