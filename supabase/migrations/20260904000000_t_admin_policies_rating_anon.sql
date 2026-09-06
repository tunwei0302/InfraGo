CREATE OR REPLACE FUNCTION current_user_is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid()
      AND lower(role::text) = 'admin'
  );
$$;

REVOKE ALL ON FUNCTION current_user_is_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION current_user_is_admin() TO authenticated;

DO $$ BEGIN
  IF to_regclass('public.driver_verifications') IS NOT NULL THEN

    DROP POLICY IF EXISTS dv_admin_queue_read ON driver_verifications;
    CREATE POLICY dv_admin_queue_read ON driver_verifications
      FOR SELECT
      TO authenticated
      USING (
        current_user_is_admin()
        OR driver_id = auth.uid()
      );

    DROP POLICY IF EXISTS dv_admin_review_update ON driver_verifications;
    CREATE POLICY dv_admin_review_update ON driver_verifications
      FOR UPDATE
      TO authenticated
      USING (current_user_is_admin() AND driver_id <> auth.uid())
      WITH CHECK (current_user_is_admin() AND driver_id <> auth.uid());

  END IF;
END $$;

CREATE OR REPLACE FUNCTION approve_driver_verification(p_driver_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reviewer UUID;
BEGIN
  IF NOT current_user_is_admin() THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'admin_only');
  END IF;
  v_reviewer := auth.uid();
  IF p_driver_id = v_reviewer THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'cannot_review_self');
  END IF;
  IF to_regclass('public.driver_verifications') IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'table_not_ready');
  END IF;
  UPDATE driver_verifications
    SET status = 'approved',
        rejection_reason = NULL,
        reviewed_by = v_reviewer,
        reviewed_at = now()
    WHERE driver_id = p_driver_id
      AND status = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'no_pending_record');
  END IF;
  RETURN jsonb_build_object('success', TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION reject_driver_verification(
  p_driver_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reviewer UUID;
BEGIN
  IF NOT current_user_is_admin() THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'admin_only');
  END IF;
  v_reviewer := auth.uid();
  IF p_driver_id = v_reviewer THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'cannot_review_self');
  END IF;
  IF p_reason IS NULL OR char_length(trim(p_reason)) < 2 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'reason_required');
  END IF;
  IF to_regclass('public.driver_verifications') IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'table_not_ready');
  END IF;
  UPDATE driver_verifications
    SET status = 'rejected',
        rejection_reason = trim(p_reason),
        reviewed_by = v_reviewer,
        reviewed_at = now()
    WHERE driver_id = p_driver_id
      AND status = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'no_pending_record');
  END IF;
  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION approve_driver_verification(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION reject_driver_verification(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION approve_driver_verification(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION reject_driver_verification(UUID, TEXT) TO authenticated;

DO $$ BEGIN
  IF to_regclass('public.driver_vehicles') IS NOT NULL THEN

    DROP POLICY IF EXISTS dveh_admin_read ON driver_vehicles;
    CREATE POLICY dveh_admin_read ON driver_vehicles
      FOR SELECT
      TO authenticated
      USING (
        current_user_is_admin()
        OR driver_id = auth.uid()
      );

    DROP POLICY IF EXISTS dveh_admin_update ON driver_vehicles;
    CREATE POLICY dveh_admin_update ON driver_vehicles
      FOR UPDATE
      TO authenticated
      USING (current_user_is_admin() AND driver_id <> auth.uid())
      WITH CHECK (current_user_is_admin() AND driver_id <> auth.uid());

  END IF;
END $$;

CREATE OR REPLACE FUNCTION approve_driver_vehicle(p_driver_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reviewer UUID;
  v_capacity INTEGER;
  v_service_eligible TEXT[];
BEGIN
  IF NOT current_user_is_admin() THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'admin_only');
  END IF;
  v_reviewer := auth.uid();
  IF p_driver_id = v_reviewer THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'cannot_review_self');
  END IF;
  IF to_regclass('public.driver_vehicles') IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'table_not_ready');
  END IF;
  SELECT passenger_capacity, service_eligibility
    INTO v_capacity, v_service_eligible
    FROM driver_vehicles WHERE driver_id = p_driver_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'no_vehicle_record');
  END IF;
  IF array_position(v_service_eligible, 'six_seater') IS NOT NULL
     AND (v_capacity IS NULL OR v_capacity < 6) THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'reason', 'six_seater_requires_capacity_6_plus',
      'submitted_capacity', v_capacity
    );
  END IF;
  UPDATE driver_vehicles
    SET approval_status = 'approved',
        rejection_reason = NULL
    WHERE driver_id = p_driver_id
      AND approval_status = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'no_pending_record');
  END IF;
  RETURN jsonb_build_object('success', TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION reject_driver_vehicle(
  p_driver_id UUID,
  p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reviewer UUID;
BEGIN
  IF NOT current_user_is_admin() THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'admin_only');
  END IF;
  v_reviewer := auth.uid();
  IF p_driver_id = v_reviewer THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'cannot_review_self');
  END IF;
  IF p_reason IS NULL OR char_length(trim(p_reason)) < 2 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'reason_required');
  END IF;
  IF to_regclass('public.driver_vehicles') IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'table_not_ready');
  END IF;
  UPDATE driver_vehicles
    SET approval_status = 'rejected',
        rejection_reason = trim(p_reason)
    WHERE driver_id = p_driver_id
      AND approval_status = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'no_pending_record');
  END IF;
  RETURN jsonb_build_object('success', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION approve_driver_vehicle(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION reject_driver_vehicle(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION approve_driver_vehicle(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION reject_driver_vehicle(UUID, TEXT) TO authenticated;

CREATE OR REPLACE VIEW driver_feedback_anonymous
WITH (security_barrier = true)
AS
SELECT
  driver_id,
  score,
  tags,
  comment,
  issue_category,
  created_at
FROM driver_ratings
ORDER BY created_at DESC;

GRANT SELECT ON driver_feedback_anonymous TO authenticated;

CREATE OR REPLACE FUNCTION admin_moderate_rating(
  p_rating_id UUID,
  p_action TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT current_user_is_admin() THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'admin_only');
  END IF;
  IF p_action = 'delete' THEN
    DELETE FROM driver_ratings WHERE id = p_rating_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', FALSE, 'reason', 'not_found');
    END IF;
    RETURN jsonb_build_object('success', TRUE);
  ELSE
    RETURN jsonb_build_object('success', FALSE, 'reason', 'unsupported_action');
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION admin_moderate_rating(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_moderate_rating(UUID, TEXT) TO authenticated;
