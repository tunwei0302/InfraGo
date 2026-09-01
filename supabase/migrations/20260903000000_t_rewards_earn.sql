-- InfraGo Tey module T5: immutable reward earn on completed+paid ride.
-- Idempotency: at most one 'earn' transaction per ride_id, enforced by a
-- partial UNIQUE index so a cancelled ride followed by a new completion
-- of a different ride cannot accidentally double-award.
-- Requires rides.status='completed' and a related payment.status='paid'.

ALTER TABLE reward_transactions
DROP CONSTRAINT IF EXISTS reward_transactions_type_check;

ALTER TABLE reward_transactions
ADD CONSTRAINT reward_transactions_type_check
CHECK (type IN ('demo_grant', 'earn', 'redeem', 'restore'));

DROP INDEX IF EXISTS idx_reward_transactions_one_earn_per_ride;
CREATE UNIQUE INDEX idx_reward_transactions_one_earn_per_ride
  ON reward_transactions(ride_id)
  WHERE type = 'earn';

CREATE OR REPLACE FUNCTION earn_completion_reward(
  p_user_id UUID,
  p_ride_id UUID,
  p_payment_id UUID,
  p_points INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account reward_accounts%ROWTYPE;
  v_ride_status TEXT;
  v_payment_status TEXT;
  v_existing INTEGER;
  v_new_balance INTEGER;
BEGIN
  IF p_user_id IS NULL OR p_ride_id IS NULL OR p_payment_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_parameters');
  END IF;
  IF p_points IS NULL OR p_points <= 0 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_points');
  END IF;

  SELECT status INTO v_ride_status FROM rides WHERE id = p_ride_id;
  IF v_ride_status IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_found');
  END IF;
  IF v_ride_status <> 'completed' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_completed');
  END IF;

  SELECT status INTO v_payment_status FROM payments WHERE id = p_payment_id;
  IF v_payment_status IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'payment_not_found');
  END IF;
  IF v_payment_status <> 'paid' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'payment_not_paid');
  END IF;

  SELECT COUNT(*) INTO v_existing
    FROM reward_transactions
    WHERE ride_id = p_ride_id AND type = 'earn';
  IF v_existing > 0 THEN
    RETURN jsonb_build_object('success', TRUE, 'reason', 'already_awarded');
  END IF;

  INSERT INTO reward_accounts (user_id) VALUES (p_user_id)
  ON CONFLICT (user_id) DO NOTHING;
  SELECT * INTO v_account FROM reward_accounts WHERE user_id = p_user_id FOR UPDATE;

  v_new_balance := v_account.points_balance + p_points;
  IF v_new_balance > 1000000 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'balance_cap_exceeded');
  END IF;

  UPDATE reward_accounts
    SET points_balance = v_new_balance, updated_at = now()
    WHERE user_id = p_user_id;
  INSERT INTO reward_transactions (
    user_id, ride_id, payment_id, type, points, balance_after
  ) VALUES (
    p_user_id, p_ride_id, p_payment_id, 'earn', p_points, v_new_balance
  );

  RETURN jsonb_build_object('success', TRUE, 'points_balance', v_new_balance);
END;
$$;

REVOKE ALL ON FUNCTION earn_completion_reward(UUID, UUID, UUID, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION earn_completion_reward(UUID, UUID, UUID, INTEGER) TO authenticated;
