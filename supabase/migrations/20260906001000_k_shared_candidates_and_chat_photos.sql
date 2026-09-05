-- Kueh: RLS-safe shared candidate discovery and private pickup photos in chat.

CREATE OR REPLACE FUNCTION list_shared_ride_candidates(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner rides%ROWTYPE;
  v_candidates JSONB;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT * INTO v_owner
  FROM rides
  WHERE id = p_ride_id AND rider_id = auth.uid();

  IF v_owner.id IS NULL
     OR v_owner.service_type != 'shared_economy'
     OR v_owner.status NOT IN ('waiting_match', 'requested')
     OR v_owner.group_id IS NOT NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT coalesce(jsonb_agg(candidate.payload), '[]'::jsonb)
  INTO v_candidates
  FROM (
    SELECT jsonb_build_object(
      'id', r.id,
      -- Deliberately anonymous: the matcher only needs to know this is not
      -- the current rider; create_carpool_match rechecks real ownership.
      'rider_id', 'anonymous-candidate',
      'status', r.status,
      'service_type', r.service_type,
      'passenger_count', r.passenger_count,
      'departure_time', r.departure_time,
      'pickup_latitude', r.pickup_latitude,
      'pickup_longitude', r.pickup_longitude,
      'destination_latitude', r.destination_latitude,
      'destination_longitude', r.destination_longitude,
      'transit_stop_id', r.transit_stop_id
    ) AS payload
    FROM rides r
    WHERE r.id != v_owner.id
      AND r.rider_id != auth.uid()
      AND r.service_type = 'shared_economy'
      AND r.status IN ('waiting_match', 'requested')
      AND r.group_id IS NULL
      AND abs(extract(epoch FROM (r.departure_time - v_owner.departure_time))) <= 900
      -- Limit disclosure before the app performs its exact 3 km haversine
      -- check. At Kuala Lumpur latitudes, 0.03 degrees is about 3.3 km.
      AND abs(r.pickup_latitude - v_owner.pickup_latitude) <= 0.03
      AND abs(r.pickup_longitude - v_owner.pickup_longitude) <= 0.03
    ORDER BY abs(extract(epoch FROM (r.departure_time - v_owner.departure_time))),
             r.created_at
    LIMIT 20
  ) candidate;

  RETURN v_candidates;
END;
$$;

REVOKE ALL ON FUNCTION list_shared_ride_candidates(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION list_shared_ride_candidates(UUID) TO authenticated;

ALTER TABLE messages ADD COLUMN IF NOT EXISTS image_path TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_one_pickup_photo_per_ride
ON messages (ride_id, image_path)
WHERE image_path IS NOT NULL;

CREATE OR REPLACE FUNCTION publish_pickup_landmark_to_chat()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.driver_id IS NOT NULL
     AND NEW.status IN ('driver_assigned', 'en_route')
     AND NEW.pickup_landmark_path IS NOT NULL
     AND NEW.pickup_landmark_path LIKE NEW.rider_id::text || '/' || NEW.id::text || '/%' THEN
    INSERT INTO messages (ride_id, sender_id, body, image_path)
    VALUES (
      NEW.id,
      NEW.rider_id,
      'Pickup landmark photo',
      NEW.pickup_landmark_path
    )
    ON CONFLICT (ride_id, image_path) WHERE image_path IS NOT NULL DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS rides_publish_pickup_landmark_to_chat ON rides;
CREATE TRIGGER rides_publish_pickup_landmark_to_chat
AFTER INSERT OR UPDATE ON rides
FOR EACH ROW EXECUTE FUNCTION publish_pickup_landmark_to_chat();
