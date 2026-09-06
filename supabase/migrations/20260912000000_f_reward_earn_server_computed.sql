DROP FUNCTION IF EXISTS earn_completion_reward(UUID, UUID, UUID, INTEGER);

CREATE OR REPLACE FUNCTION earn_completion_reward(
  p_ride_id UUID,
  p_payment_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride rides%ROWTYPE;
  v_payment payments%ROWTYPE;
  v_account reward_accounts%ROWTYPE;
  v_existing INTEGER;
  v_points INTEGER;
  v_new_balance INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  IF p_ride_id IS NULL OR p_payment_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_parameters');
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_found');
  END IF;
  IF auth.uid() NOT IN (v_ride.rider_id, v_ride.driver_id) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_a_ride_participant');
  END IF;
  IF v_ride.status <> 'completed' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_completed');
  END IF;

  SELECT * INTO v_payment FROM payments WHERE id = p_payment_id;
  IF v_payment.id IS NULL OR v_payment.ride_id <> p_ride_id THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'payment_not_found');
  END IF;
  IF v_payment.status <> 'paid' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'payment_not_paid');
  END IF;

  SELECT COUNT(*) INTO v_existing
    FROM reward_transactions
    WHERE ride_id = p_ride_id AND type = 'earn';
  IF v_existing > 0 THEN
    RETURN jsonb_build_object('success', TRUE, 'reason', 'already_awarded');
  END IF;

  v_points := floor(COALESCE(v_payment.final_amount, 0) * 10)::INTEGER;
  IF v_points <= 0 THEN
    RETURN jsonb_build_object('success', TRUE, 'reason', 'no_reward_points', 'points_awarded', 0);
  END IF;

  INSERT INTO reward_accounts (user_id) VALUES (v_ride.rider_id)
  ON CONFLICT (user_id) DO NOTHING;
  SELECT * INTO v_account FROM reward_accounts WHERE user_id = v_ride.rider_id FOR UPDATE;

  v_new_balance := v_account.points_balance + v_points;
  IF v_new_balance > 1000000 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'balance_cap_exceeded');
  END IF;

  UPDATE reward_accounts
    SET points_balance = v_new_balance, updated_at = now()
    WHERE user_id = v_ride.rider_id;
  INSERT INTO reward_transactions (
    user_id, ride_id, payment_id, type, points, balance_after
  ) VALUES (
    v_ride.rider_id, p_ride_id, p_payment_id, 'earn', v_points, v_new_balance
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'points_balance', v_new_balance,
    'points_awarded', v_points
  );
END;
$$;

REVOKE ALL ON FUNCTION earn_completion_reward(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION earn_completion_reward(UUID, UUID) TO authenticated;
