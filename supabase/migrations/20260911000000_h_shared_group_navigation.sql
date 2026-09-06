-- Heng: complete the driver-side four-stop shared-ride workflow.

ALTER TABLE ride_groups
  ADD COLUMN IF NOT EXISTS current_stop_idx INTEGER
    CHECK (current_stop_idx IS NULL OR current_stop_idx BETWEEN 0 AND 3);

ALTER TABLE ride_groups
  ADD COLUMN IF NOT EXISTS stop_arrived_at TIMESTAMPTZ[];

CREATE OR REPLACE FUNCTION initialise_shared_group_stop()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.driver_id IS NOT NULL
     AND NEW.status = 'driver_assigned'
     AND NEW.current_stop_idx IS NULL THEN
    NEW.current_stop_idx := 0;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS ride_groups_initialise_shared_stop ON ride_groups;
CREATE TRIGGER ride_groups_initialise_shared_stop
BEFORE UPDATE OF driver_id, status ON ride_groups
FOR EACH ROW EXECUTE FUNCTION initialise_shared_group_stop();

-- Repair groups accepted before current_stop_idx was deployed.
UPDATE ride_groups
SET current_stop_idx = 0
WHERE driver_id IS NOT NULL
  AND status IN ('driver_assigned', 'en_route')
  AND current_stop_idx IS NULL;

-- The previous Heng enhancement migration accidentally expected
-- `ready_to_match`; Kueh's atomic matcher creates groups as `matched`.
-- Reinstall the claim RPC with the canonical state and initialise stop 0 in
-- the same transaction so a newly assigned driver always has a target.
CREATE OR REPLACE FUNCTION accept_carpool_group(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group ride_groups%ROWTYPE;
  v_vehicle driver_vehicles%ROWTYPE;
  v_member_count INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;

  SELECT * INTO v_vehicle
  FROM driver_vehicles
  WHERE driver_id = auth.uid()
  FOR UPDATE;

  IF NOT EXISTS (
       SELECT 1 FROM driver_verifications
       WHERE driver_id = auth.uid() AND approval_status = 'approved'
     )
     OR v_vehicle.driver_id IS NULL
     OR v_vehicle.approval_status != 'approved' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_not_ready');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM driver_presence presence
    WHERE presence.driver_id = auth.uid()
      AND presence.is_online = TRUE
      AND presence.is_assigned = FALSE
      AND presence.last_seen_at >= now() - INTERVAL '30 seconds'
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_not_online');
  END IF;

  SELECT * INTO v_group
  FROM ride_groups
  WHERE id = p_group_id
  FOR UPDATE;

  IF v_group.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_found');
  END IF;
  IF v_group.status != 'matched' OR v_group.driver_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_available');
  END IF;

  SELECT count(*) INTO v_member_count
  FROM ride_group_members
  WHERE group_id = v_group.id;
  IF v_member_count != 2 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_group_members');
  END IF;
  IF EXISTS (
    SELECT 1 FROM ride_group_members
    WHERE group_id = v_group.id AND rider_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_cannot_accept_own_group');
  END IF;
  IF v_vehicle.passenger_capacity < v_group.total_passengers THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'vehicle_capacity_incompatible');
  END IF;

  UPDATE ride_groups
  SET driver_id = auth.uid(), status = 'driver_assigned', current_stop_idx = 0
  WHERE id = v_group.id;

  UPDATE rides
  SET driver_id = auth.uid(), status = 'driver_assigned',
      accepted_at = now(), free_cancel_until = now() + INTERVAL '3 minutes'
  WHERE id IN (
    SELECT ride_id FROM ride_group_members WHERE group_id = v_group.id
  );

  UPDATE driver_presence
  SET is_assigned = TRUE
  WHERE driver_id = auth.uid();

  RETURN jsonb_build_object(
    'success', TRUE,
    'group_id', v_group.id,
    'status', 'driver_assigned',
    'current_stop_idx', 0,
    'stop_count', 4
  );
END;
$$;

CREATE OR REPLACE FUNCTION advance_group_stop_pointer(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group ride_groups%ROWTYPE;
  v_current_idx INTEGER;
  v_next_idx INTEGER;
  v_stop_count INTEGER;
  v_stop_code INTEGER;
  v_stop_ride_id UUID;
  v_stop_kind TEXT;
  v_arrivals TIMESTAMPTZ[];
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;

  SELECT * INTO v_group
  FROM ride_groups
  WHERE id = p_group_id
  FOR UPDATE;

  IF v_group.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_found');
  END IF;
  IF v_group.driver_id IS NULL OR v_group.driver_id != auth.uid() THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_assigned_driver');
  END IF;
  IF v_group.status NOT IN ('driver_assigned', 'en_route') THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_in_progress');
  END IF;

  v_stop_count := array_length(v_group.optimised_stop_order, 1);
  IF v_stop_count IS NULL OR v_stop_count != 4 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_stop_plan');
  END IF;

  v_current_idx := coalesce(v_group.current_stop_idx, 0);
  v_stop_code := v_group.optimised_stop_order[v_current_idx + 1];
  v_stop_kind := CASE WHEN v_stop_code < 2 THEN 'pickup' ELSE 'dropoff' END;

  SELECT member.ride_id INTO v_stop_ride_id
  FROM ride_group_members member
  WHERE member.group_id = v_group.id
    AND CASE
      WHEN v_stop_code < 2 THEN member.stop_index_pickup = v_current_idx
      ELSE member.stop_index_destination = v_current_idx
    END;
  IF v_stop_ride_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'stop_member_not_found');
  END IF;

  v_arrivals := coalesce(v_group.stop_arrived_at, ARRAY[]::TIMESTAMPTZ[])
    || ARRAY[now()]::TIMESTAMPTZ[];

  -- Complete each rider independently at that rider's own drop-off. The
  -- shared group remains active until the final drop-off is confirmed.
  IF v_stop_kind = 'pickup' THEN
    UPDATE rides
    SET status = 'en_route'
    WHERE id = v_stop_ride_id AND driver_id = auth.uid();
  ELSE
    UPDATE rides
    SET status = 'completed', completed_at = now()
    WHERE id = v_stop_ride_id AND driver_id = auth.uid();

    DELETE FROM assigned_driver_location
    WHERE ride_id = v_stop_ride_id;
  END IF;

  IF v_current_idx >= v_stop_count - 1 THEN
    UPDATE ride_groups
    SET status = 'completed', completed_at = now(),
        current_stop_idx = v_stop_count - 1,
        stop_arrived_at = v_arrivals
    WHERE id = v_group.id;

    UPDATE driver_presence
    SET is_assigned = FALSE
    WHERE driver_id = auth.uid();

    DELETE FROM assigned_driver_location
    WHERE ride_id IN (
      SELECT ride_id FROM ride_group_members WHERE group_id = v_group.id
    );

    RETURN jsonb_build_object(
      'success', TRUE,
      'completed', TRUE,
      'confirmed_stop_idx', v_current_idx,
      'confirmed_stop_code', v_stop_code,
      'confirmed_stop_kind', v_stop_kind,
      'confirmed_ride_id', v_stop_ride_id,
      'current_stop_idx', v_current_idx,
      'remaining_stops', 0,
      'group_status', 'completed'
    );
  END IF;

  v_next_idx := v_current_idx + 1;
  UPDATE ride_groups
  SET status = 'en_route', current_stop_idx = v_next_idx,
      stop_arrived_at = v_arrivals
  WHERE id = v_group.id;

  UPDATE rides
  SET status = 'en_route'
  WHERE group_id = v_group.id AND driver_id = auth.uid();

  RETURN jsonb_build_object(
    'success', TRUE,
    'completed', FALSE,
    'confirmed_stop_idx', v_current_idx,
    'confirmed_stop_code', v_stop_code,
    'confirmed_stop_kind', v_stop_kind,
    'confirmed_ride_id', v_stop_ride_id,
    'current_stop_idx', v_next_idx,
    'next_stop_code', v_group.optimised_stop_order[v_next_idx + 1],
    'remaining_stops', v_stop_count - v_next_idx,
    'group_status', 'en_route'
  );
END;
$$;

-- Repair drop-offs that were confirmed while the previous implementation
-- still kept every member ride en_route until the group finished. The active
-- pointer identifies stops strictly before it as already confirmed.
UPDATE rides ride
SET status = 'completed',
    completed_at = coalesce(
      shared_group.stop_arrived_at[member.stop_index_destination + 1],
      now()
    )
FROM ride_group_members member
JOIN ride_groups shared_group ON shared_group.id = member.group_id
WHERE ride.id = member.ride_id
  AND shared_group.status IN ('driver_assigned', 'en_route')
  AND shared_group.current_stop_idx IS NOT NULL
  AND member.stop_index_destination < shared_group.current_stop_idx
  AND ride.status != 'completed';

DELETE FROM assigned_driver_location location
USING rides ride
WHERE location.ride_id = ride.id
  AND ride.status = 'completed';

REVOKE ALL ON FUNCTION advance_group_stop_pointer(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION accept_carpool_group(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advance_group_stop_pointer(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION accept_carpool_group(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
