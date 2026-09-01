-- InfraGo Tey module: fix wrong column name in the T3 identity review RPCs.
--
-- driver_verifications (created in 20260902000000_h_driver_operations.sql)
-- has an `approval_status` column, not `status`. approve_driver_verification
-- and reject_driver_verification (20260904000000_t_admin_policies_rating_
-- anon.sql) were written against a `status` column that never existed,
-- so both RPCs fail at runtime with "column driver_verifications.status
-- does not exist" - the entire T3 identity approve/reject flow was broken.
-- (lib/tey/admin_review_repository.dart's fetchPendingIdentities() has the
-- same mistake and is fixed alongside this migration.)
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
    SET approval_status = 'approved',
        rejection_reason = NULL,
        reviewed_by = v_reviewer,
        reviewed_at = now()
    WHERE driver_id = p_driver_id
      AND approval_status = 'pending';
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
    SET approval_status = 'rejected',
        rejection_reason = trim(p_reason),
        reviewed_by = v_reviewer,
        reviewed_at = now()
    WHERE driver_id = p_driver_id
      AND approval_status = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'no_pending_record');
  END IF;
  RETURN jsonb_build_object('success', TRUE);
END;
$$;
