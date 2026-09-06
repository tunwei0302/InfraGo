CREATE TABLE IF NOT EXISTS reward_accounts (
  user_id UUID PRIMARY KEY,
  points_balance INTEGER NOT NULL DEFAULT 0 CHECK (points_balance >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS reward_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES reward_accounts(user_id) ON DELETE CASCADE,
  ride_id UUID,
  payment_id UUID,
  type TEXT NOT NULL CHECK (type IN ('demo_grant', 'redeem', 'restore')),
  points INTEGER NOT NULL,
  balance_after INTEGER NOT NULL CHECK (balance_after >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reward_transactions_user
  ON reward_transactions(user_id, created_at DESC);

CREATE OR REPLACE FUNCTION ensure_reward_account()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account reward_accounts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  INSERT INTO reward_accounts (user_id) VALUES (auth.uid())
  ON CONFLICT (user_id) DO NOTHING;
  SELECT * INTO v_account FROM reward_accounts WHERE user_id = auth.uid();
  RETURN jsonb_build_object('success', TRUE, 'points_balance', v_account.points_balance);
END;
$$;

CREATE OR REPLACE FUNCTION demo_reward_grant(p_points INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account reward_accounts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  IF p_points IS NULL OR p_points <= 0 OR p_points > 1000 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_points');
  END IF;

  INSERT INTO reward_accounts (user_id) VALUES (auth.uid())
  ON CONFLICT (user_id) DO NOTHING;
  SELECT * INTO v_account FROM reward_accounts WHERE user_id = auth.uid() FOR UPDATE;

  IF v_account.points_balance + p_points > 100000 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'demo_balance_cap_exceeded');
  END IF;

  UPDATE reward_accounts SET points_balance = points_balance + p_points, updated_at = now()
  WHERE user_id = auth.uid();
  INSERT INTO reward_transactions (user_id, type, points, balance_after)
  VALUES (auth.uid(), 'demo_grant', p_points, v_account.points_balance + p_points);

  RETURN jsonb_build_object('success', TRUE, 'points_balance', v_account.points_balance + p_points);
END;
$$;

CREATE OR REPLACE FUNCTION redeem_reward_points(
  p_user_id UUID,
  p_points INTEGER,
  p_ride_id UUID,
  p_payment_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account reward_accounts%ROWTYPE;
BEGIN
  IF p_points <= 0 THEN
    RETURN;
  END IF;
  INSERT INTO reward_accounts (user_id) VALUES (p_user_id) ON CONFLICT DO NOTHING;
  SELECT * INTO v_account FROM reward_accounts WHERE user_id = p_user_id FOR UPDATE;
  IF v_account.points_balance < p_points THEN
    RAISE EXCEPTION 'insufficient_reward_points';
  END IF;
  UPDATE reward_accounts SET points_balance = points_balance - p_points, updated_at = now()
  WHERE user_id = p_user_id;
  INSERT INTO reward_transactions (user_id, ride_id, payment_id, type, points, balance_after)
  VALUES (p_user_id, p_ride_id, p_payment_id, 'redeem', -p_points, v_account.points_balance - p_points);
END;
$$;

CREATE OR REPLACE FUNCTION restore_reward_points(
  p_user_id UUID,
  p_points INTEGER,
  p_ride_id UUID,
  p_payment_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account reward_accounts%ROWTYPE;
BEGIN
  IF p_points <= 0 THEN
    RETURN;
  END IF;
  INSERT INTO reward_accounts (user_id) VALUES (p_user_id) ON CONFLICT DO NOTHING;
  SELECT * INTO v_account FROM reward_accounts WHERE user_id = p_user_id FOR UPDATE;
  UPDATE reward_accounts SET points_balance = points_balance + p_points, updated_at = now()
  WHERE user_id = p_user_id;
  INSERT INTO reward_transactions (user_id, ride_id, payment_id, type, points, balance_after)
  VALUES (p_user_id, p_ride_id, p_payment_id, 'restore', p_points, v_account.points_balance + p_points);
END;
$$;

REVOKE ALL ON FUNCTION ensure_reward_account() FROM PUBLIC;
REVOKE ALL ON FUNCTION demo_reward_grant(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION redeem_reward_points(UUID, INTEGER, UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION restore_reward_points(UUID, INTEGER, UUID, UUID) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION ensure_reward_account() TO authenticated;
GRANT EXECUTE ON FUNCTION demo_reward_grant(INTEGER) TO authenticated;

ALTER TABLE reward_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE reward_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS reward_accounts_owner_read ON reward_accounts;
CREATE POLICY reward_accounts_owner_read ON reward_accounts FOR SELECT USING (user_id = auth.uid());

DROP POLICY IF EXISTS reward_transactions_owner_read ON reward_transactions;
CREATE POLICY reward_transactions_owner_read ON reward_transactions FOR SELECT USING (user_id = auth.uid());
