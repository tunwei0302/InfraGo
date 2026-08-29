-- InfraGo Foo module: fare quotes, cash/demo-wallet payments, wallet ledger
-- and cancellation settlement. Apply only after reviewing it with the owner
-- of rides (Kueh) since it extends the shared rides table.

ALTER TABLE rides ADD COLUMN IF NOT EXISTS pickup_landmark_path TEXT;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS accepted_at TIMESTAMPTZ;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS free_cancel_until TIMESTAMPTZ;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS cancelled_by TEXT;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS cancellation_policy_version TEXT;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS cancellation_fee NUMERIC(10, 2);

DO $$ BEGIN
  ALTER TABLE rides ADD CONSTRAINT rides_cancelled_by_check
    CHECK (cancelled_by IS NULL OR cancelled_by IN ('rider', 'driver', 'system'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS fare_quotes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id UUID NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  pricing_version TEXT NOT NULL,
  service_type TEXT NOT NULL
    CHECK (service_type IN ('economy_4', 'six_seater', 'shared_economy')),
  distance_meters DOUBLE PRECISION NOT NULL CHECK (distance_meters >= 0),
  duration_seconds DOUBLE PRECISION NOT NULL CHECK (duration_seconds >= 0),
  base_amount NUMERIC(10, 2) NOT NULL CHECK (base_amount >= 0),
  vehicle_multiplier NUMERIC(4, 2) NOT NULL CHECK (vehicle_multiplier > 0),
  solo_amount NUMERIC(10, 2) NOT NULL CHECK (solo_amount >= 0),
  shared_amount NUMERIC(10, 2) CHECK (shared_amount IS NULL OR shared_amount >= 0),
  currency TEXT NOT NULL DEFAULT 'MYR',
  quoted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_fare_quotes_ride ON fare_quotes(ride_id, quoted_at DESC);

CREATE TABLE IF NOT EXISTS wallet_accounts (
  user_id UUID PRIMARY KEY,
  balance NUMERIC(10, 2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
  currency TEXT NOT NULL DEFAULT 'MYR',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id UUID NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  group_id UUID REFERENCES ride_groups(id) ON DELETE SET NULL,
  payer_id UUID NOT NULL,
  method TEXT NOT NULL CHECK (method IN ('cash', 'demo_wallet')),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'authorised', 'paid', 'failed', 'refunded', 'cancelled')),
  idempotency_key TEXT NOT NULL UNIQUE,
  quoted_amount NUMERIC(10, 2) NOT NULL CHECK (quoted_amount >= 0),
  discount_amount NUMERIC(10, 2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  cancellation_fee NUMERIC(10, 2) NOT NULL DEFAULT 0 CHECK (cancellation_fee >= 0),
  refunded_amount NUMERIC(10, 2) NOT NULL DEFAULT 0 CHECK (refunded_amount >= 0),
  driver_compensation_amount NUMERIC(10, 2) NOT NULL DEFAULT 0 CHECK (driver_compensation_amount >= 0),
  final_amount NUMERIC(10, 2),
  currency TEXT NOT NULL DEFAULT 'MYR',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_payments_current_per_ride
  ON payments(ride_id) WHERE status IN ('pending', 'authorised', 'paid');
CREATE INDEX IF NOT EXISTS idx_payments_payer ON payments(payer_id, created_at DESC);

CREATE TABLE IF NOT EXISTS wallet_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_user_id UUID NOT NULL REFERENCES wallet_accounts(user_id) ON DELETE CASCADE,
  ride_id UUID REFERENCES rides(id) ON DELETE SET NULL,
  payment_id UUID REFERENCES payments(id) ON DELETE SET NULL,
  type TEXT NOT NULL
    CHECK (type IN ('demo_topup', 'authorise', 'refund')),
  amount NUMERIC(10, 2) NOT NULL,
  balance_after NUMERIC(10, 2) NOT NULL CHECK (balance_after >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_wallet_transactions_user
  ON wallet_transactions(wallet_user_id, created_at DESC);

-- Internal helper: derives the amount actually owed for a ride from its most
-- recent fare_quotes row, so payment RPCs never trust a client-supplied
-- amount. Only callable from other SECURITY DEFINER functions in this file.
CREATE OR REPLACE FUNCTION resolve_current_fare_amount(p_ride_id UUID)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride rides%ROWTYPE;
  v_quote fare_quotes%ROWTYPE;
BEGIN
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'ride_not_found';
  END IF;

  SELECT * INTO v_quote FROM fare_quotes
  WHERE ride_id = p_ride_id ORDER BY quoted_at DESC LIMIT 1;
  IF v_quote.id IS NULL THEN
    RAISE EXCEPTION 'fare_quote_not_found';
  END IF;

  IF v_quote.service_type = 'shared_economy' AND v_ride.group_id IS NOT NULL THEN
    RETURN COALESCE(v_quote.shared_amount, v_quote.solo_amount);
  END IF;
  RETURN v_quote.solo_amount;
END;
$$;

CREATE OR REPLACE FUNCTION ensure_wallet_account()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet wallet_accounts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  INSERT INTO wallet_accounts (user_id) VALUES (auth.uid())
  ON CONFLICT (user_id) DO NOTHING;
  SELECT * INTO v_wallet FROM wallet_accounts WHERE user_id = auth.uid();
  RETURN jsonb_build_object('success', TRUE, 'balance', v_wallet.balance, 'currency', v_wallet.currency);
END;
$$;

-- Coursework-only fake top-up so the demo wallet payment path is testable
-- without ever touching real money. Never expose an equivalent for real
-- currency.
CREATE OR REPLACE FUNCTION demo_wallet_top_up(p_amount NUMERIC)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet wallet_accounts%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount > 500 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_amount');
  END IF;

  INSERT INTO wallet_accounts (user_id) VALUES (auth.uid())
  ON CONFLICT (user_id) DO NOTHING;
  SELECT * INTO v_wallet FROM wallet_accounts WHERE user_id = auth.uid() FOR UPDATE;

  IF v_wallet.balance + p_amount > 5000 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'demo_balance_cap_exceeded');
  END IF;

  UPDATE wallet_accounts SET balance = balance + p_amount, updated_at = now()
  WHERE user_id = auth.uid();
  INSERT INTO wallet_transactions (wallet_user_id, type, amount, balance_after)
  VALUES (auth.uid(), 'demo_topup', p_amount, v_wallet.balance + p_amount);

  RETURN jsonb_build_object('success', TRUE, 'balance', v_wallet.balance + p_amount);
END;
$$;

CREATE OR REPLACE FUNCTION create_cash_payment(p_ride_id UUID, p_idempotency_key TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride rides%ROWTYPE;
  v_existing payments%ROWTYPE;
  v_payment payments%ROWTYPE;
  v_amount NUMERIC;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;

  SELECT * INTO v_existing FROM payments WHERE idempotency_key = p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', TRUE, 'payment_id', v_existing.id,
      'status', v_existing.status, 'idempotent_replay', TRUE
    );
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL OR v_ride.rider_id != auth.uid() THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_ride_owner');
  END IF;
  IF v_ride.status IN ('completed', 'cancelled') THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_open');
  END IF;
  IF EXISTS (
    SELECT 1 FROM payments
    WHERE ride_id = p_ride_id AND status IN ('pending', 'authorised', 'paid')
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'payment_already_exists');
  END IF;

  v_amount := resolve_current_fare_amount(p_ride_id);

  INSERT INTO payments (ride_id, group_id, payer_id, method, status, idempotency_key, quoted_amount)
  VALUES (p_ride_id, v_ride.group_id, auth.uid(), 'cash', 'pending', p_idempotency_key, v_amount)
  RETURNING * INTO v_payment;

  RETURN jsonb_build_object(
    'success', TRUE, 'payment_id', v_payment.id,
    'status', v_payment.status, 'amount', v_payment.quoted_amount
  );
EXCEPTION WHEN unique_violation THEN
  SELECT * INTO v_existing FROM payments WHERE idempotency_key = p_idempotency_key;
  IF v_existing.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'payment_already_exists');
  END IF;
  RETURN jsonb_build_object(
    'success', TRUE, 'payment_id', v_existing.id,
    'status', v_existing.status, 'idempotent_replay', TRUE
  );
END;
$$;

CREATE OR REPLACE FUNCTION complete_cash_payment(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride rides%ROWTYPE;
  v_payment payments%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL OR auth.uid() NOT IN (v_ride.rider_id, v_ride.driver_id) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_a_ride_participant');
  END IF;

  SELECT * INTO v_payment FROM payments
  WHERE ride_id = p_ride_id AND method = 'cash' FOR UPDATE;
  IF v_payment.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'payment_not_found');
  END IF;
  IF v_payment.status = 'paid' THEN
    RETURN jsonb_build_object('success', TRUE, 'payment_id', v_payment.id, 'status', 'paid', 'idempotent_replay', TRUE);
  END IF;
  IF v_payment.status != 'pending' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_payment_state');
  END IF;

  UPDATE payments SET
    status = 'paid',
    final_amount = quoted_amount - discount_amount,
    updated_at = now()
  WHERE id = v_payment.id;

  RETURN jsonb_build_object('success', TRUE, 'payment_id', v_payment.id, 'status', 'paid');
END;
$$;

CREATE OR REPLACE FUNCTION create_wallet_payment(p_ride_id UUID, p_idempotency_key TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride rides%ROWTYPE;
  v_existing payments%ROWTYPE;
  v_payment payments%ROWTYPE;
  v_amount NUMERIC;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;

  SELECT * INTO v_existing FROM payments WHERE idempotency_key = p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', TRUE, 'payment_id', v_existing.id,
      'status', v_existing.status, 'idempotent_replay', TRUE
    );
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL OR v_ride.rider_id != auth.uid() THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_ride_owner');
  END IF;
  IF v_ride.status IN ('completed', 'cancelled') THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_open');
  END IF;
  IF EXISTS (
    SELECT 1 FROM payments
    WHERE ride_id = p_ride_id AND status IN ('pending', 'authorised', 'paid')
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'payment_already_exists');
  END IF;

  v_amount := resolve_current_fare_amount(p_ride_id);

  INSERT INTO payments (ride_id, group_id, payer_id, method, status, idempotency_key, quoted_amount)
  VALUES (p_ride_id, v_ride.group_id, auth.uid(), 'demo_wallet', 'pending', p_idempotency_key, v_amount)
  RETURNING * INTO v_payment;

  RETURN jsonb_build_object(
    'success', TRUE, 'payment_id', v_payment.id,
    'status', v_payment.status, 'amount', v_payment.quoted_amount
  );
EXCEPTION WHEN unique_violation THEN
  SELECT * INTO v_existing FROM payments WHERE idempotency_key = p_idempotency_key;
  IF v_existing.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'payment_already_exists');
  END IF;
  RETURN jsonb_build_object(
    'success', TRUE, 'payment_id', v_existing.id,
    'status', v_existing.status, 'idempotent_replay', TRUE
  );
END;
$$;

-- Reserves funds when a driver accepts. Deducts immediately into the
-- 'authorised' state rather than tracking a separate hold amount; capture
-- is then a pure status transition with no further balance movement.
CREATE OR REPLACE FUNCTION authorise_wallet_payment(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride rides%ROWTYPE;
  v_payment payments%ROWTYPE;
  v_wallet wallet_accounts%ROWTYPE;
  v_charge NUMERIC;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL OR auth.uid() NOT IN (v_ride.rider_id, v_ride.driver_id) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_a_ride_participant');
  END IF;

  SELECT * INTO v_payment FROM payments
  WHERE ride_id = p_ride_id AND method = 'demo_wallet' FOR UPDATE;
  IF v_payment.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'payment_not_found');
  END IF;
  IF v_payment.status = 'authorised' THEN
    RETURN jsonb_build_object('success', TRUE, 'payment_id', v_payment.id, 'status', 'authorised', 'idempotent_replay', TRUE);
  END IF;
  IF v_payment.status != 'pending' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_payment_state');
  END IF;

  v_charge := v_payment.quoted_amount - v_payment.discount_amount;

  INSERT INTO wallet_accounts (user_id) VALUES (v_payment.payer_id) ON CONFLICT DO NOTHING;
  SELECT * INTO v_wallet FROM wallet_accounts WHERE user_id = v_payment.payer_id FOR UPDATE;

  IF v_wallet.balance < v_charge THEN
    RETURN jsonb_build_object(
      'success', FALSE, 'reason', 'insufficient_balance',
      'balance', v_wallet.balance, 'required', v_charge
    );
  END IF;

  UPDATE wallet_accounts SET balance = balance - v_charge, updated_at = now()
  WHERE user_id = v_payment.payer_id;
  INSERT INTO wallet_transactions (wallet_user_id, ride_id, payment_id, type, amount, balance_after)
  VALUES (v_payment.payer_id, p_ride_id, v_payment.id, 'authorise', -v_charge, v_wallet.balance - v_charge);

  UPDATE payments SET status = 'authorised', updated_at = now() WHERE id = v_payment.id;

  RETURN jsonb_build_object('success', TRUE, 'payment_id', v_payment.id, 'status', 'authorised');
END;
$$;

CREATE OR REPLACE FUNCTION capture_wallet_payment(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride rides%ROWTYPE;
  v_payment payments%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL OR auth.uid() NOT IN (v_ride.rider_id, v_ride.driver_id) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_a_ride_participant');
  END IF;

  SELECT * INTO v_payment FROM payments
  WHERE ride_id = p_ride_id AND method = 'demo_wallet' FOR UPDATE;
  IF v_payment.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'payment_not_found');
  END IF;
  IF v_payment.status = 'paid' THEN
    RETURN jsonb_build_object('success', TRUE, 'payment_id', v_payment.id, 'status', 'paid', 'idempotent_replay', TRUE);
  END IF;
  IF v_payment.status != 'authorised' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_payment_state');
  END IF;

  UPDATE payments SET
    status = 'paid',
    final_amount = quoted_amount - discount_amount,
    updated_at = now()
  WHERE id = v_payment.id;

  RETURN jsonb_build_object('success', TRUE, 'payment_id', v_payment.id, 'status', 'paid');
END;
$$;

-- Cancels a ride and settles its current payment in one transaction so the
-- cancellation fee, refund and rides.cancellation_* fields are all written
-- exactly once. Cash never moves money: the fee is only recorded as the
-- prototype amount due.
CREATE OR REPLACE FUNCTION cancel_ride_and_settle_payment(
  p_ride_id UUID,
  p_cancelled_by TEXT,
  p_reason TEXT,
  p_policy_version TEXT,
  p_fee NUMERIC,
  p_driver_compensation NUMERIC DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride rides%ROWTYPE;
  v_payment payments%ROWTYPE;
  v_wallet wallet_accounts%ROWTYPE;
  v_held NUMERIC;
  v_refund NUMERIC;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  IF p_cancelled_by NOT IN ('rider', 'driver', 'system') THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_cancelled_by');
  END IF;
  IF p_fee IS NULL OR p_fee < 0 OR p_driver_compensation IS NULL OR p_driver_compensation < 0 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_amount');
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_found');
  END IF;
  IF auth.uid() NOT IN (v_ride.rider_id, v_ride.driver_id) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_a_ride_participant');
  END IF;
  IF v_ride.status IN ('completed', 'cancelled') THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_cancellable');
  END IF;

  UPDATE rides SET
    status = 'cancelled',
    cancelled_at = now(),
    cancelled_by = p_cancelled_by,
    cancellation_reason = p_reason,
    cancellation_policy_version = p_policy_version,
    cancellation_fee = p_fee
  WHERE id = p_ride_id;

  SELECT * INTO v_payment FROM payments
  WHERE ride_id = p_ride_id AND status IN ('pending', 'authorised', 'paid') FOR UPDATE;

  IF v_payment.id IS NULL THEN
    RETURN jsonb_build_object('success', TRUE, 'payment_settled', FALSE);
  END IF;

  IF v_payment.method = 'cash' THEN
    UPDATE payments SET
      status = 'cancelled',
      cancellation_fee = p_fee,
      driver_compensation_amount = p_driver_compensation,
      refunded_amount = 0,
      final_amount = p_fee,
      updated_at = now()
    WHERE id = v_payment.id;
    RETURN jsonb_build_object(
      'success', TRUE, 'payment_id', v_payment.id, 'method', 'cash', 'amount_due', p_fee
    );
  END IF;

  IF v_payment.status = 'pending' THEN
    UPDATE payments SET
      status = 'cancelled',
      cancellation_fee = p_fee,
      driver_compensation_amount = p_driver_compensation,
      refunded_amount = 0,
      final_amount = p_fee,
      updated_at = now()
    WHERE id = v_payment.id;
    RETURN jsonb_build_object(
      'success', TRUE, 'payment_id', v_payment.id, 'method', 'demo_wallet', 'refunded_amount', 0
    );
  END IF;

  v_held := v_payment.quoted_amount - v_payment.discount_amount;
  v_refund := GREATEST(v_held - p_fee, 0);

  INSERT INTO wallet_accounts (user_id) VALUES (v_payment.payer_id) ON CONFLICT DO NOTHING;
  SELECT * INTO v_wallet FROM wallet_accounts WHERE user_id = v_payment.payer_id FOR UPDATE;

  UPDATE wallet_accounts SET balance = balance + v_refund, updated_at = now()
  WHERE user_id = v_payment.payer_id;
  INSERT INTO wallet_transactions (wallet_user_id, ride_id, payment_id, type, amount, balance_after)
  VALUES (v_payment.payer_id, p_ride_id, v_payment.id, 'refund', v_refund, v_wallet.balance + v_refund);

  UPDATE payments SET
    status = 'refunded',
    cancellation_fee = p_fee,
    driver_compensation_amount = p_driver_compensation,
    refunded_amount = v_refund,
    final_amount = p_fee,
    updated_at = now()
  WHERE id = v_payment.id;

  RETURN jsonb_build_object(
    'success', TRUE, 'payment_id', v_payment.id, 'method', 'demo_wallet', 'refunded_amount', v_refund
  );
END;
$$;

REVOKE ALL ON FUNCTION resolve_current_fare_amount(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION ensure_wallet_account() FROM PUBLIC;
REVOKE ALL ON FUNCTION demo_wallet_top_up(NUMERIC) FROM PUBLIC;
REVOKE ALL ON FUNCTION create_cash_payment(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION complete_cash_payment(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION create_wallet_payment(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION authorise_wallet_payment(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION capture_wallet_payment(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION cancel_ride_and_settle_payment(UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION ensure_wallet_account() TO authenticated;
GRANT EXECUTE ON FUNCTION demo_wallet_top_up(NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION create_cash_payment(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION complete_cash_payment(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION create_wallet_payment(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION authorise_wallet_payment(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION capture_wallet_payment(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_ride_and_settle_payment(UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC) TO authenticated;

ALTER TABLE fare_quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fare_quotes_rider_read ON fare_quotes;
CREATE POLICY fare_quotes_rider_read ON fare_quotes FOR SELECT USING (
  EXISTS (SELECT 1 FROM rides r WHERE r.id = fare_quotes.ride_id AND r.rider_id = auth.uid())
);

-- Direct client insert is safe here: a quote is a single append-only row and
-- ownership is enforced below. No UPDATE/DELETE policy exists, so an
-- accepted quote can never be silently changed once written.
DROP POLICY IF EXISTS fare_quotes_rider_insert ON fare_quotes;
CREATE POLICY fare_quotes_rider_insert ON fare_quotes FOR INSERT WITH CHECK (
  EXISTS (SELECT 1 FROM rides r WHERE r.id = fare_quotes.ride_id AND r.rider_id = auth.uid())
);

-- Payments and the wallet ledger have no client insert/update/delete
-- policy at all: every mutation goes through the SECURITY DEFINER
-- functions above, which is what makes them atomic and immutable.
DROP POLICY IF EXISTS payments_payer_read ON payments;
CREATE POLICY payments_payer_read ON payments FOR SELECT USING (payer_id = auth.uid());

DROP POLICY IF EXISTS wallet_accounts_owner_read ON wallet_accounts;
CREATE POLICY wallet_accounts_owner_read ON wallet_accounts FOR SELECT USING (user_id = auth.uid());

DROP POLICY IF EXISTS wallet_transactions_owner_read ON wallet_transactions;
CREATE POLICY wallet_transactions_owner_read ON wallet_transactions FOR SELECT USING (wallet_user_id = auth.uid());
