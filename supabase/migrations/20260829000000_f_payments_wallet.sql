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
  reward_points_redeemed INTEGER NOT NULL DEFAULT 0 CHECK (reward_points_redeemed >= 0),
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

  IF v_quote.service_type = 'shared_economy' THEN
    IF v_ride.group_id IS NOT NULL THEN
      RETURN COALESCE(v_quote.shared_amount, v_quote.solo_amount);
    END IF;
    RETURN v_quote.solo_amount;
  END IF;
  RETURN ROUND((v_quote.base_amount * v_quote.vehicle_multiplier)::numeric, 2);
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

CREATE OR REPLACE FUNCTION create_cash_payment(
  p_ride_id UUID,
  p_idempotency_key TEXT,
  p_discount_amount NUMERIC DEFAULT 0,
  p_reward_points_redeemed INTEGER DEFAULT 0
)
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

  INSERT INTO payments (
    ride_id, group_id, payer_id, method, status, idempotency_key,
    quoted_amount, discount_amount, reward_points_redeemed
  )
  VALUES (
    p_ride_id, v_ride.group_id, auth.uid(), 'cash', 'pending', p_idempotency_key,
    v_amount, p_discount_amount, p_reward_points_redeemed
  )
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

CREATE OR REPLACE FUNCTION create_wallet_payment(
  p_ride_id UUID,
  p_idempotency_key TEXT,
  p_discount_amount NUMERIC DEFAULT 0,
  p_reward_points_redeemed INTEGER DEFAULT 0
)
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

  INSERT INTO payments (
    ride_id, group_id, payer_id, method, status, idempotency_key,
    quoted_amount, discount_amount, reward_points_redeemed
  )
  VALUES (
    p_ride_id, v_ride.group_id, auth.uid(), 'demo_wallet', 'pending', p_idempotency_key,
    v_amount, p_discount_amount, p_reward_points_redeemed
  )
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

-- Creates the ride, its fare_quotes row and its payment row in a single
-- transaction: if any step fails, none of it is persisted. Recomputes the
-- mvp_v1 fare from route distance/duration itself rather than trusting a
-- client-supplied amount, so the Dart FareEstimator is only ever a display
-- estimate; this function is the one authoritative price. p_client_request_id
-- is a client-generated idempotency key covering the whole operation: a
-- retry with the same key returns the original ride/payment instead of
-- creating a second ride.
CREATE OR REPLACE FUNCTION create_ride_with_quote_and_payment(
  p_pickup_label TEXT,
  p_destination_label TEXT,
  p_pickup_lat DOUBLE PRECISION,
  p_pickup_lng DOUBLE PRECISION,
  p_destination_lat DOUBLE PRECISION,
  p_destination_lng DOUBLE PRECISION,
  p_service_type TEXT,
  p_passenger_count INTEGER,
  p_departure_time TIMESTAMPTZ,
  p_route_distance_meters DOUBLE PRECISION,
  p_route_duration_seconds DOUBLE PRECISION,
  p_payment_method TEXT,
  p_client_request_id TEXT,
  p_pickup_note TEXT DEFAULT NULL,
  p_transit_stop_id TEXT DEFAULT NULL,
  p_transit_stop_name TEXT DEFAULT NULL,
  p_reward_points_to_redeem INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing_payment payments%ROWTYPE;
  v_ride_id UUID;
  v_status TEXT;
  v_km DOUBLE PRECISION;
  v_minutes DOUBLE PRECISION;
  v_raw NUMERIC;
  v_economy NUMERIC;
  v_multiplier NUMERIC;
  v_shared_amount NUMERIC;
  v_solo_fare NUMERIC;
  v_charge_amount NUMERIC;
  v_redemption_amount NUMERIC;
  v_reward_account reward_accounts%ROWTYPE;
  v_payment_result JSONB;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;

  SELECT * INTO v_existing_payment FROM payments WHERE idempotency_key = p_client_request_id;
  IF v_existing_payment.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', TRUE, 'ride_id', v_existing_payment.ride_id,
      'payment_id', v_existing_payment.id, 'status', v_existing_payment.status,
      'idempotent_replay', TRUE
    );
  END IF;

  IF p_service_type NOT IN ('economy_4', 'six_seater', 'shared_economy') THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_service_type');
  END IF;
  IF p_payment_method NOT IN ('cash', 'demo_wallet') THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_payment_method');
  END IF;
  IF p_route_distance_meters < 0 OR p_route_duration_seconds < 0 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_route');
  END IF;

  v_km := p_route_distance_meters / 1000.0;
  v_minutes := p_route_duration_seconds / 60.0;
  v_raw := 3.0 + 1.10 * v_km + 0.20 * v_minutes;
  v_economy := GREATEST(5.0, v_raw);
  v_multiplier := CASE p_service_type
    WHEN 'six_seater' THEN 1.35
    WHEN 'shared_economy' THEN 0.75
    ELSE 1.0
  END;
  v_shared_amount := CASE WHEN p_service_type = 'shared_economy'
    THEN ROUND((v_economy * 0.75)::numeric, 2)
    ELSE NULL
  END;
  v_solo_fare := CASE WHEN p_service_type = 'shared_economy'
    THEN NULL
    ELSE ROUND((v_economy * v_multiplier)::numeric, 2)
  END;
  v_status := CASE WHEN p_service_type = 'shared_economy' THEN 'waiting_match' ELSE 'requested' END;
  v_charge_amount := CASE WHEN p_service_type = 'shared_economy'
    THEN ROUND(v_economy::numeric, 2)
    ELSE ROUND((v_economy * v_multiplier)::numeric, 2)
  END;

  IF p_reward_points_to_redeem IS NULL OR p_reward_points_to_redeem < 0 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_reward_points');
  END IF;
  v_redemption_amount := ROUND(p_reward_points_to_redeem / 100.0, 2);
  IF p_reward_points_to_redeem > 0 THEN
    IF v_redemption_amount > ROUND(v_charge_amount * 0.20, 2) THEN
      RETURN jsonb_build_object('success', FALSE, 'reason', 'reward_redemption_exceeds_limit');
    END IF;
    SELECT * INTO v_reward_account FROM reward_accounts WHERE user_id = auth.uid() FOR UPDATE;
    IF v_reward_account.user_id IS NULL OR v_reward_account.points_balance < p_reward_points_to_redeem THEN
      RETURN jsonb_build_object('success', FALSE, 'reason', 'insufficient_reward_points');
    END IF;
  END IF;

  INSERT INTO rides (
    rider_id, pickup, destination,
    pickup_latitude, pickup_longitude, destination_latitude, destination_longitude,
    status, service_type, passenger_count, departure_time,
    route_distance_meters, route_duration_seconds,
    pickup_note, transit_stop_id, transit_stop_name,
    estimated_solo_fare, estimated_shared_fare
  ) VALUES (
    auth.uid(), p_pickup_label, p_destination_label,
    p_pickup_lat, p_pickup_lng, p_destination_lat, p_destination_lng,
    v_status, p_service_type, p_passenger_count, p_departure_time,
    p_route_distance_meters, p_route_duration_seconds,
    p_pickup_note, p_transit_stop_id, p_transit_stop_name,
    v_solo_fare, v_shared_amount
  ) RETURNING id INTO v_ride_id;

  INSERT INTO fare_quotes (
    ride_id, pricing_version, service_type, distance_meters, duration_seconds,
    base_amount, vehicle_multiplier, solo_amount, shared_amount, currency
  ) VALUES (
    v_ride_id, 'mvp_v1', p_service_type, p_route_distance_meters, p_route_duration_seconds,
    ROUND(v_economy::numeric, 2), v_multiplier, ROUND(v_economy::numeric, 2), v_shared_amount, 'MYR'
  );

  IF p_payment_method = 'cash' THEN
    v_payment_result := create_cash_payment(
      v_ride_id, p_client_request_id, v_redemption_amount, p_reward_points_to_redeem
    );
  ELSE
    v_payment_result := create_wallet_payment(
      v_ride_id, p_client_request_id, v_redemption_amount, p_reward_points_to_redeem
    );
  END IF;

  IF (v_payment_result->>'success')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'payment_setup_failed: %', v_payment_result->>'reason';
  END IF;

  IF p_reward_points_to_redeem > 0 THEN
    PERFORM redeem_reward_points(
      auth.uid(), p_reward_points_to_redeem, v_ride_id,
      (v_payment_result->>'payment_id')::uuid
    );
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE, 'ride_id', v_ride_id,
    'payment_id', v_payment_result->>'payment_id', 'status', v_payment_result->>'status'
  );
EXCEPTION WHEN unique_violation THEN
  SELECT * INTO v_existing_payment FROM payments WHERE idempotency_key = p_client_request_id;
  IF v_existing_payment.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'duplicate_request');
  END IF;
  RETURN jsonb_build_object(
    'success', TRUE, 'ride_id', v_existing_payment.ride_id,
    'payment_id', v_existing_payment.id, 'status', v_existing_payment.status,
    'idempotent_replay', TRUE
  );
END;
$$;

-- Converts an unmatched shared request to Economy and updates its fare and
-- pending payment atomically. This prevents the rider from seeing a solo ride
-- that still charges the discounted shared amount.
CREATE OR REPLACE FUNCTION continue_shared_ride_solo(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride rides%ROWTYPE;
  v_quote fare_quotes%ROWTYPE;
  v_payment payments%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL OR v_ride.rider_id != auth.uid() THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_owned');
  END IF;
  IF v_ride.service_type != 'shared_economy'
     OR v_ride.group_id IS NOT NULL
     OR v_ride.status NOT IN ('requested', 'waiting_match') THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_convertible');
  END IF;

  SELECT * INTO v_quote FROM fare_quotes
  WHERE ride_id = p_ride_id ORDER BY quoted_at DESC LIMIT 1 FOR UPDATE;
  SELECT * INTO v_payment FROM payments
  WHERE ride_id = p_ride_id AND status = 'pending' FOR UPDATE;
  IF v_quote.id IS NULL OR v_payment.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'pending_quote_or_payment_not_found');
  END IF;

  UPDATE rides SET
    service_type = 'economy_4',
    status = 'requested',
    estimated_shared_fare = NULL,
    estimated_solo_fare = v_quote.solo_amount
  WHERE id = p_ride_id;
  INSERT INTO fare_quotes (
    ride_id, pricing_version, service_type, distance_meters, duration_seconds,
    base_amount, vehicle_multiplier, solo_amount, shared_amount, currency
  ) VALUES (
    p_ride_id, v_quote.pricing_version, 'economy_4', v_quote.distance_meters,
    v_quote.duration_seconds, v_quote.base_amount, 1.00,
    v_quote.solo_amount, NULL, v_quote.currency
  );
  UPDATE payments SET
    quoted_amount = v_quote.solo_amount,
    updated_at = now()
  WHERE id = v_payment.id;

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'payment_id', v_payment.id,
    'amount', v_quote.solo_amount
  );
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
    group_id = NULL,
    cancelled_at = now(),
    cancelled_by = p_cancelled_by,
    cancellation_reason = p_reason,
    cancellation_policy_version = p_policy_version,
    cancellation_fee = p_fee
  WHERE id = p_ride_id;

  -- A shared booking must not leave its partner trapped in a matched group.
  -- Before driver assignment the partner returns to matching; after assignment
  -- it keeps the same driver as a solo continuation. The cancelled group and
  -- all of its obsolete member rows are retired in this same transaction.
  IF v_ride.group_id IS NOT NULL THEN
    UPDATE rides SET
      group_id = NULL,
      status = CASE WHEN status = 'matched' THEN 'waiting_match' ELSE status END
    WHERE group_id = v_ride.group_id AND id != p_ride_id;

    DELETE FROM ride_group_members WHERE group_id = v_ride.group_id;
    UPDATE ride_groups SET status = 'cancelled', cancelled_at = now()
    WHERE id = v_ride.group_id;
  END IF;

  SELECT * INTO v_payment FROM payments
  WHERE ride_id = p_ride_id AND status IN ('pending', 'authorised', 'paid') FOR UPDATE;

  IF v_payment.id IS NULL THEN
    RETURN jsonb_build_object('success', TRUE, 'payment_settled', FALSE);
  END IF;

  IF v_payment.reward_points_redeemed > 0 THEN
    PERFORM restore_reward_points(
      v_payment.payer_id, v_payment.reward_points_redeemed, p_ride_id, v_payment.id
    );
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
REVOKE ALL ON FUNCTION create_cash_payment(UUID, TEXT, NUMERIC, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION complete_cash_payment(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION create_wallet_payment(UUID, TEXT, NUMERIC, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION authorise_wallet_payment(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION capture_wallet_payment(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION continue_shared_ride_solo(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION create_ride_with_quote_and_payment(
  TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
  TEXT, INTEGER, TIMESTAMPTZ, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER
) FROM PUBLIC;
REVOKE ALL ON FUNCTION cancel_ride_and_settle_payment(UUID, TEXT, TEXT, TEXT, NUMERIC, NUMERIC) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION ensure_wallet_account() TO authenticated;
GRANT EXECUTE ON FUNCTION demo_wallet_top_up(NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION create_cash_payment(UUID, TEXT, NUMERIC, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION complete_cash_payment(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION create_wallet_payment(UUID, TEXT, NUMERIC, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION authorise_wallet_payment(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION capture_wallet_payment(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION continue_shared_ride_solo(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION create_ride_with_quote_and_payment(
  TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION,
  TEXT, INTEGER, TIMESTAMPTZ, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER
) TO authenticated;
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
