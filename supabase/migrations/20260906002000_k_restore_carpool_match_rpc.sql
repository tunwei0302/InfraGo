-- Restore the current 10-argument carpool RPC without removing the original
-- 9-argument signature that may already be used by older clients.

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
  v_result JSONB;
  v_group_id UUID;
BEGIN
  -- Delegate validation, row locks and atomic group creation to the original
  -- function. auth.uid() remains the authenticated caller inside that RPC.
  v_result := create_carpool_match(
    p_ride_a,
    p_ride_b,
    p_match_score,
    p_match_reasons,
    p_stop_order,
    p_detour_a,
    p_detour_b,
    p_route_distance_meters,
    p_route_duration_seconds
  );

  IF coalesce((v_result ->> 'success')::BOOLEAN, FALSE) THEN
    v_group_id := (v_result ->> 'group_id')::UUID;
    UPDATE ride_groups
    SET vehicle_km_avoided = greatest(0, p_vehicle_km_avoided)
    WHERE id = v_group_id;
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION create_carpool_match(
  UUID, UUID, INTEGER, TEXT[], INTEGER[], DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_carpool_match(
  UUID, UUID, INTEGER, TEXT[], INTEGER[], DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION
) TO authenticated;

NOTIFY pgrst, 'reload schema';
