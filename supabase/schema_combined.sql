-- ==========================================================================
-- InfraGo combined schema reference
-- ==========================================================================
-- Auto-generated for READING/REFERENCE ONLY by concatenating every file in
-- supabase/migrations/ in chronological (filename) order.
--
-- This file is NOT a Supabase migration and must never be placed in
-- supabase/migrations/ or run against a database directly -- the individual
-- migration files remain the source of truth for schema history and are
-- already tracked/applied against the live project. Regenerate this file
-- whenever the migrations folder changes.
-- ==========================================================================

-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260828000000_k_trip_planner.sql
-- --------------------------------------------------------------------------
-- InfraGo Kueh module: trip planning, shared rides, nearby driver privacy,
-- transit-stop read contract and rider-driver chat lifecycle.
-- Apply only after reviewing it with the owners of rides/messages.

ALTER TABLE rides ADD COLUMN IF NOT EXISTS service_type TEXT NOT NULL DEFAULT 'economy_4';
ALTER TABLE rides ADD COLUMN IF NOT EXISTS passenger_count INTEGER NOT NULL DEFAULT 1;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS departure_time TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE rides ADD COLUMN IF NOT EXISTS pickup_latitude DOUBLE PRECISION;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS pickup_longitude DOUBLE PRECISION;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS destination_latitude DOUBLE PRECISION;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS destination_longitude DOUBLE PRECISION;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS route_distance_meters DOUBLE PRECISION;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS route_duration_seconds DOUBLE PRECISION;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS pickup_note TEXT;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS transit_stop_id TEXT;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS transit_stop_name TEXT;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS estimated_solo_fare NUMERIC(10, 2);
ALTER TABLE rides ADD COLUMN IF NOT EXISTS estimated_shared_fare NUMERIC(10, 2);
ALTER TABLE rides ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS cancellation_reason TEXT;

UPDATE rides
SET service_type = CASE service_type
  WHEN 'standard' THEN 'economy_4'
  WHEN 'economy' THEN 'economy_4'
  WHEN 'suv' THEN 'six_seater'
  ELSE service_type
END
WHERE service_type IN ('standard', 'economy', 'suv');

DO $$ BEGIN
  ALTER TABLE rides ADD CONSTRAINT rides_service_type_check
    CHECK (service_type IN ('economy_4', 'six_seater', 'shared_economy'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  ALTER TABLE rides ADD CONSTRAINT rides_passenger_count_check
    CHECK (
      passenger_count BETWEEN 1 AND 6
      AND (service_type != 'shared_economy' OR passenger_count <= 2)
      AND (service_type != 'economy_4' OR passenger_count <= 4)
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS ride_groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  status TEXT NOT NULL DEFAULT 'matched'
    CHECK (status IN ('searching', 'matched', 'driver_assigned', 'en_route', 'completed', 'cancelled')),
  total_passengers INTEGER NOT NULL CHECK (total_passengers BETWEEN 2 AND 4),
  match_score INTEGER NOT NULL CHECK (match_score BETWEEN 60 AND 100),
  match_reasons TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  optimised_stop_order INTEGER[] NOT NULL,
  route_distance_meters DOUBLE PRECISION NOT NULL,
  route_duration_seconds DOUBLE PRECISION NOT NULL,
  vehicle_km_avoided DOUBLE PRECISION,
  driver_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  matched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ
);

ALTER TABLE rides ADD COLUMN IF NOT EXISTS group_id UUID REFERENCES ride_groups(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS ride_group_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES ride_groups(id) ON DELETE CASCADE,
  ride_id UUID NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  rider_id UUID NOT NULL,
  stop_index_pickup INTEGER NOT NULL CHECK (stop_index_pickup BETWEEN 0 AND 3),
  stop_index_destination INTEGER NOT NULL CHECK (stop_index_destination BETWEEN 0 AND 3),
  detour_percent DOUBLE PRECISION NOT NULL CHECK (detour_percent BETWEEN 0 AND 25),
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (group_id, ride_id),
  UNIQUE (ride_id),
  CHECK (stop_index_pickup < stop_index_destination)
);

CREATE INDEX IF NOT EXISTS idx_rides_shared_candidates
  ON rides(service_type, status, departure_time);
CREATE INDEX IF NOT EXISTS idx_ride_group_members_group ON ride_group_members(group_id);

CREATE TABLE IF NOT EXISTS driver_presence (
  driver_id UUID PRIMARY KEY,
  anonymised_id TEXT NOT NULL UNIQUE,
  coarse_lat DOUBLE PRECISION NOT NULL,
  coarse_lng DOUBLE PRECISION NOT NULL,
  vehicle_categories TEXT[] NOT NULL DEFAULT ARRAY['economy_4']::TEXT[],
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_online BOOLEAN NOT NULL DEFAULT FALSE,
  is_assigned BOOLEAN NOT NULL DEFAULT FALSE,
  heading DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS assigned_driver_location (
  ride_id UUID PRIMARY KEY REFERENCES rides(id) ON DELETE CASCADE,
  driver_id UUID NOT NULL,
  exact_lat DOUBLE PRECISION NOT NULL,
  exact_lng DOUBLE PRECISION NOT NULL,
  vehicle_plate TEXT NOT NULL,
  heading DOUBLE PRECISION,
  seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS transit_stops (
  stop_id TEXT PRIMARY KEY,
  stop_code TEXT,
  stop_name TEXT NOT NULL,
  route_name TEXT,
  latitude DOUBLE PRECISION NOT NULL,
  longitude DOUBLE PRECISION NOT NULL,
  source TEXT NOT NULL DEFAULT 'data.gov.my GTFS Static',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE VIEW nearby_driver_presence
WITH (security_barrier = true)
AS
SELECT anonymised_id, coarse_lat, coarse_lng, vehicle_categories,
       last_seen_at, is_online, is_assigned, heading
FROM driver_presence
WHERE is_online = TRUE
  AND is_assigned = FALSE
  AND last_seen_at >= now() - INTERVAL '60 seconds';

REVOKE ALL ON driver_presence FROM anon, authenticated;
GRANT SELECT ON nearby_driver_presence TO authenticated;

CREATE OR REPLACE FUNCTION upsert_my_driver_presence(
  p_coarse_lat DOUBLE PRECISION,
  p_coarse_lng DOUBLE PRECISION,
  p_vehicle_categories TEXT[],
  p_is_online BOOLEAN,
  p_is_assigned BOOLEAN,
  p_heading DOUBLE PRECISION DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;
  INSERT INTO driver_presence (
    driver_id, anonymised_id, coarse_lat, coarse_lng, vehicle_categories,
    is_online, is_assigned, heading, last_seen_at
  ) VALUES (
    auth.uid(),
    'V-' || upper(substr(md5(auth.uid()::TEXT || current_date::TEXT), 1, 8)),
    p_coarse_lat, p_coarse_lng,
    p_vehicle_categories, p_is_online, p_is_assigned, p_heading, now()
  )
  ON CONFLICT (driver_id) DO UPDATE SET
    anonymised_id = EXCLUDED.anonymised_id,
    coarse_lat = EXCLUDED.coarse_lat,
    coarse_lng = EXCLUDED.coarse_lng,
    vehicle_categories = EXCLUDED.vehicle_categories,
    is_online = EXCLUDED.is_online,
    is_assigned = EXCLUDED.is_assigned,
    heading = EXCLUDED.heading,
    last_seen_at = now();
END;
$$;

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
  v_a rides%ROWTYPE;
  v_b rides%ROWTYPE;
  v_group_id UUID;
  v_pickup_a INTEGER;
  v_drop_a INTEGER;
  v_pickup_b INTEGER;
  v_drop_b INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  IF p_ride_a = p_ride_b OR p_match_score < 60 OR p_match_score > 100 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_match');
  END IF;
  IF p_detour_a < 0 OR p_detour_a > 25 OR p_detour_b < 0 OR p_detour_b > 25 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'detour_limit');
  END IF;
  IF array_length(p_stop_order, 1) != 4 OR
     (SELECT COUNT(DISTINCT value) FROM unnest(p_stop_order) value) != 4 OR
     NOT (p_stop_order @> ARRAY[0,1,2,3]) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_stop_order');
  END IF;

  SELECT * INTO v_a FROM rides WHERE id = p_ride_a FOR UPDATE;
  SELECT * INTO v_b FROM rides WHERE id = p_ride_b FOR UPDATE;
  IF v_a.id IS NULL OR v_b.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_found');
  END IF;
  IF auth.uid() NOT IN (v_a.rider_id, v_b.rider_id) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_a_ride_owner');
  END IF;
  IF v_a.rider_id = v_b.rider_id THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'same_rider');
  END IF;
  IF v_a.service_type != 'shared_economy' OR v_b.service_type != 'shared_economy'
     OR v_a.status NOT IN ('waiting_match', 'requested')
     OR v_b.status NOT IN ('waiting_match', 'requested')
     OR v_a.group_id IS NOT NULL OR v_b.group_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_available');
  END IF;
  IF v_a.passenger_count + v_b.passenger_count > 4 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'capacity_exceeded');
  END IF;
  IF abs(extract(epoch FROM (v_a.departure_time - v_b.departure_time))) > 900 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'departure_gap');
  END IF;

  v_pickup_a := array_position(p_stop_order, 0) - 1;
  v_pickup_b := array_position(p_stop_order, 1) - 1;
  v_drop_a := array_position(p_stop_order, 2) - 1;
  v_drop_b := array_position(p_stop_order, 3) - 1;
  IF v_pickup_a >= v_drop_a OR v_pickup_b >= v_drop_b THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'pickup_after_dropoff');
  END IF;

  INSERT INTO ride_groups (
    status, total_passengers, match_score, match_reasons,
    optimised_stop_order, route_distance_meters, route_duration_seconds,
    vehicle_km_avoided
  ) VALUES (
    'matched', v_a.passenger_count + v_b.passenger_count, p_match_score,
    p_match_reasons, p_stop_order, p_route_distance_meters,
    p_route_duration_seconds, GREATEST(0, p_vehicle_km_avoided)
  ) RETURNING id INTO v_group_id;

  INSERT INTO ride_group_members (
    group_id, ride_id, rider_id, stop_index_pickup,
    stop_index_destination, detour_percent
  ) VALUES
    (v_group_id, v_a.id, v_a.rider_id, v_pickup_a, v_drop_a, p_detour_a),
    (v_group_id, v_b.id, v_b.rider_id, v_pickup_b, v_drop_b, p_detour_b);

  UPDATE rides SET group_id = v_group_id, status = 'matched'
  WHERE id IN (v_a.id, v_b.id);
  RETURN jsonb_build_object('success', TRUE, 'group_id', v_group_id);
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('success', FALSE, 'reason', 'concurrent_match_lost');
END;
$$;

CREATE OR REPLACE FUNCTION cancel_carpool_group_membership(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group_id UUID;
BEGIN
  SELECT group_id INTO v_group_id FROM rides
  WHERE id = p_ride_id AND rider_id = auth.uid() FOR UPDATE;
  IF v_group_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_owned_or_not_grouped');
  END IF;
  UPDATE rides SET group_id = NULL, status = 'cancelled', cancelled_at = now()
  WHERE id = p_ride_id AND rider_id = auth.uid();
  UPDATE rides SET
    group_id = NULL,
    status = CASE WHEN status = 'matched' THEN 'waiting_match' ELSE status END
  WHERE group_id = v_group_id AND id != p_ride_id;
  DELETE FROM ride_group_members WHERE group_id = v_group_id;
  UPDATE ride_groups SET status = 'cancelled', cancelled_at = now()
  WHERE id = v_group_id;
  RETURN jsonb_build_object('success', TRUE, 'group_id', v_group_id);
END;
$$;

REVOKE ALL ON FUNCTION upsert_my_driver_presence(
  DOUBLE PRECISION, DOUBLE PRECISION, TEXT[], BOOLEAN, BOOLEAN,
  DOUBLE PRECISION
) FROM PUBLIC;
REVOKE ALL ON FUNCTION create_carpool_match(
  UUID, UUID, INTEGER, TEXT[], INTEGER[], DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION
) FROM PUBLIC;
-- Drivers claim a matched group as one atomic unit: the group row and every
-- member ride become driver_assigned in the same transaction, which is also
-- the precondition the chat insert policy needs to open the conversations.
CREATE OR REPLACE FUNCTION accept_carpool_group(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group ride_groups%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  SELECT * INTO v_group FROM ride_groups WHERE id = p_group_id FOR UPDATE;
  IF v_group.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_found');
  END IF;
  IF v_group.status != 'matched' OR v_group.driver_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_available');
  END IF;
  IF EXISTS (
    SELECT 1 FROM ride_group_members
    WHERE group_id = v_group.id AND rider_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'rider_cannot_accept_own_group');
  END IF;

  UPDATE ride_groups
  SET driver_id = auth.uid(), status = 'driver_assigned'
  WHERE id = v_group.id;

  UPDATE rides
  SET driver_id = auth.uid(), status = 'driver_assigned'
  WHERE id IN (
    SELECT ride_id FROM ride_group_members WHERE group_id = v_group.id
  );

  RETURN jsonb_build_object('success', TRUE, 'group_id', v_group.id);
END;
$$;

REVOKE ALL ON FUNCTION cancel_carpool_group_membership(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION upsert_my_driver_presence(
  DOUBLE PRECISION, DOUBLE PRECISION, TEXT[], BOOLEAN, BOOLEAN,
  DOUBLE PRECISION
) TO authenticated;
GRANT EXECUTE ON FUNCTION create_carpool_match(
  UUID, UUID, INTEGER, TEXT[], INTEGER[], DOUBLE PRECISION, DOUBLE PRECISION,
  DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION
) TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_carpool_group_membership(UUID) TO authenticated;
REVOKE ALL ON FUNCTION accept_carpool_group(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION accept_carpool_group(UUID) TO authenticated;

ALTER TABLE ride_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE ride_group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE assigned_driver_location ENABLE ROW LEVEL SECURITY;
ALTER TABLE transit_stops ENABLE ROW LEVEL SECURITY;
-- No policies: the coarse presence table is database-owned. Drivers publish
-- only through upsert_my_driver_presence, which derives the anonymised id
-- server-side; riders read it only through nearby_driver_presence.
ALTER TABLE driver_presence ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ride_groups_participant_read ON ride_groups;
CREATE POLICY ride_groups_participant_read ON ride_groups FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM ride_group_members gm
    JOIN rides r ON r.id = gm.ride_id
    WHERE gm.group_id = ride_groups.id
      AND (r.rider_id = auth.uid() OR r.driver_id = auth.uid())
  )
);

DROP POLICY IF EXISTS ride_group_members_participant_read ON ride_group_members;
CREATE POLICY ride_group_members_participant_read ON ride_group_members FOR SELECT USING (
  rider_id = auth.uid() OR EXISTS (
    SELECT 1 FROM rides assigned
    WHERE assigned.id = ride_group_members.ride_id
      AND assigned.driver_id = auth.uid()
  )
);

DROP POLICY IF EXISTS assigned_location_participant_read ON assigned_driver_location;
CREATE POLICY assigned_location_participant_read ON assigned_driver_location FOR SELECT USING (
  driver_id = auth.uid() OR EXISTS (
    SELECT 1 FROM rides r
    WHERE r.id = assigned_driver_location.ride_id
      AND r.rider_id = auth.uid()
      AND r.driver_id = assigned_driver_location.driver_id
  )
);

DROP POLICY IF EXISTS transit_stops_authenticated_read ON transit_stops;
CREATE POLICY transit_stops_authenticated_read ON transit_stops FOR SELECT
USING (auth.uid() IS NOT NULL);

-- Each ride has its own rider-driver conversation. A rider never receives the
-- other rider's messages merely because both rides belong to one group.
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS messages_trip_participant_read ON messages;
CREATE POLICY messages_trip_participant_read ON messages FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM rides r
    WHERE r.id = messages.ride_id
      AND (r.rider_id = auth.uid() OR r.driver_id = auth.uid())
  )
);

DROP POLICY IF EXISTS messages_trip_participant_insert ON messages;
CREATE POLICY messages_trip_participant_insert ON messages FOR INSERT WITH CHECK (
  sender_id = auth.uid() AND EXISTS (
    SELECT 1 FROM rides r
    WHERE r.id = messages.ride_id
      AND (r.rider_id = auth.uid() OR r.driver_id = auth.uid())
      AND r.driver_id IS NOT NULL
      AND r.status IN ('driver_assigned', 'en_route')
  )
);


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260829000000_f_payments_wallet.sql
-- --------------------------------------------------------------------------
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


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260830000000_f_pickup_landmark_storage.sql
-- --------------------------------------------------------------------------
-- InfraGo Foo module: private storage for optional pickup-landmark photos.
-- Object path convention: {rider_id}/{ride_id}/photo.{ext} so RLS can scope
-- both the uploading rider and the eventually-assigned driver without a
-- lookup table. Apply only after reviewing it with the team.

INSERT INTO storage.buckets (id, name, public)
VALUES ('pickup-landmarks', 'pickup-landmarks', FALSE)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS pickup_landmarks_rider_write ON storage.objects;
CREATE POLICY pickup_landmarks_rider_write ON storage.objects
FOR INSERT WITH CHECK (
  bucket_id = 'pickup-landmarks'
  AND (storage.foldername(name))[1] = auth.uid()::text
  AND EXISTS (
    SELECT 1 FROM rides r
    WHERE r.id::text = (storage.foldername(name))[2]
      AND r.rider_id = auth.uid()
  )
);

DROP POLICY IF EXISTS pickup_landmarks_rider_overwrite ON storage.objects;
CREATE POLICY pickup_landmarks_rider_overwrite ON storage.objects
FOR UPDATE USING (
  bucket_id = 'pickup-landmarks'
  AND (storage.foldername(name))[1] = auth.uid()::text
) WITH CHECK (
  bucket_id = 'pickup-landmarks'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS pickup_landmarks_rider_read ON storage.objects;
CREATE POLICY pickup_landmarks_rider_read ON storage.objects
FOR SELECT USING (
  bucket_id = 'pickup-landmarks'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS pickup_landmarks_driver_read ON storage.objects;
CREATE POLICY pickup_landmarks_driver_read ON storage.objects
FOR SELECT USING (
  bucket_id = 'pickup-landmarks'
  AND EXISTS (
    SELECT 1 FROM rides r
    WHERE r.id::text = (storage.foldername(name))[2]
      AND r.driver_id = auth.uid()
  )
);


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260831000000_t_rewards.sql
-- --------------------------------------------------------------------------
-- InfraGo Tey module: reward points balance and immutable ledger.
-- Built now so Foo's payment RPCs (20260829000000_f_payments_wallet.sql) can
-- reserve and deduct reward points atomically with a ride's payment (F7).
-- Prototype rate: 100 points = RM1. Apply only after reviewing it with the
-- team; ownership of this module belongs to Tey.

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

-- Coursework-only fake grant so reward redemption is testable without a
-- real earn-by-riding system. Never expose an equivalent that mints real
-- value.
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

-- Internal: atomically debits points from a rider's reward balance and
-- writes the ledger entry. Callers (Foo's create_ride_with_quote_and_payment)
-- are expected to have already validated the 20%-of-fare cap and checked the
-- balance; the balance check here is a defensive backstop against a
-- concurrent redemption racing the same account.
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

-- Internal: credits points back after a refund/cancellation. Called from
-- Foo's cancel_ride_and_settle_payment in the same transaction as the fee
-- and refund, so the restore is atomic with the cancellation.
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


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260901000000_t_driver_ratings.sql
-- --------------------------------------------------------------------------
-- InfraGo Tey module: one rating per completed ride, driver sees only
-- aggregated/anonymised feedback. Built now, standing in for Tey, so
-- Foo's receipt screen has something real to hand off to (F6's "opens
-- rating flow if unrated"). Apply only after reviewing it with the team;
-- ownership of this module belongs to Tey.

CREATE TABLE IF NOT EXISTS driver_ratings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id UUID NOT NULL UNIQUE REFERENCES rides(id) ON DELETE CASCADE,
  rider_id UUID NOT NULL,
  driver_id UUID NOT NULL,
  score INTEGER NOT NULL CHECK (score BETWEEN 1 AND 5),
  tags TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  comment TEXT CHECK (comment IS NULL OR char_length(comment) <= 300),
  issue_category TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_driver_ratings_driver ON driver_ratings(driver_id);

-- Drivers never query the base table directly (RLS below limits SELECT to
-- the rider who wrote it), so this is the only way a driver sees feedback:
-- aggregated, with no rider identity attached.
CREATE OR REPLACE VIEW driver_rating_summary
WITH (security_barrier = true)
AS
SELECT
  driver_id,
  COUNT(*) AS rating_count,
  ROUND(AVG(score)::numeric, 2) AS average_score
FROM driver_ratings
GROUP BY driver_id;

GRANT SELECT ON driver_rating_summary TO authenticated;

ALTER TABLE driver_ratings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS driver_ratings_rider_read ON driver_ratings;
CREATE POLICY driver_ratings_rider_read ON driver_ratings FOR SELECT USING (
  rider_id = auth.uid()
);

-- One rating per ride is enforced by the UNIQUE constraint on ride_id, not
-- just this check, so a race between two inserts still fails cleanly.
DROP POLICY IF EXISTS driver_ratings_rider_insert ON driver_ratings;
CREATE POLICY driver_ratings_rider_insert ON driver_ratings FOR INSERT WITH CHECK (
  rider_id = auth.uid()
  AND EXISTS (
    SELECT 1 FROM rides r
    WHERE r.id = driver_ratings.ride_id
      AND r.rider_id = auth.uid()
      AND r.driver_id = driver_ratings.driver_id
      AND r.status = 'completed'
  )
);


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260902000000_h_driver_operations.sql
-- --------------------------------------------------------------------------
-- InfraGo Heng module: manual driver/vehicle review, secure documents,
-- approved presence, atomic acceptance and guarded ride lifecycle.

ALTER TABLE rides ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS driver_verifications (
  driver_id UUID PRIMARY KEY,
  display_name TEXT NOT NULL CHECK (char_length(trim(display_name)) BETWEEN 2 AND 80),
  contact TEXT NOT NULL CHECK (char_length(trim(contact)) BETWEEN 5 AND 80),
  licence_path TEXT NOT NULL,
  selfie_path TEXT NOT NULL,
  approval_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (approval_status IN ('pending', 'approved', 'rejected')),
  rejection_reason TEXT,
  reviewed_by UUID,
  reviewed_at TIMESTAMPTZ,
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS driver_vehicles (
  driver_id UUID PRIMARY KEY,
  make TEXT NOT NULL CHECK (char_length(trim(make)) BETWEEN 2 AND 50),
  model TEXT NOT NULL CHECK (char_length(trim(model)) BETWEEN 1 AND 50),
  color TEXT NOT NULL CHECK (char_length(trim(color)) BETWEEN 2 AND 30),
  body_type TEXT NOT NULL CHECK (body_type IN ('sedan', 'hatchback', 'mpv', 'suv')),
  plate_number TEXT NOT NULL UNIQUE
    CHECK (plate_number ~ '^[A-Z0-9]{3,12}$'),
  passenger_capacity INTEGER NOT NULL CHECK (passenger_capacity BETWEEN 1 AND 6),
  approval_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (approval_status IN ('pending', 'approved', 'rejected')),
  rejection_reason TEXT,
  reviewed_by UUID,
  reviewed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'driver-documents', 'driver-documents', FALSE, 5242880,
  ARRAY['image/jpeg', 'image/png']
)
ON CONFLICT (id) DO UPDATE SET
  public = FALSE,
  file_size_limit = 5242880,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png'];

ALTER TABLE driver_verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_vehicles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS driver_verification_owner_read ON driver_verifications;
CREATE POLICY driver_verification_owner_read ON driver_verifications
FOR SELECT USING (driver_id = auth.uid());

DROP POLICY IF EXISTS driver_vehicle_owner_read ON driver_vehicles;
CREATE POLICY driver_vehicle_owner_read ON driver_vehicles
FOR SELECT USING (driver_id = auth.uid());

DROP POLICY IF EXISTS driver_documents_owner_insert ON storage.objects;
CREATE POLICY driver_documents_owner_insert ON storage.objects FOR INSERT
TO authenticated WITH CHECK (
  bucket_id = 'driver-documents'
  AND (storage.foldername(name))[1] = auth.uid()::TEXT
);

DROP POLICY IF EXISTS driver_documents_owner_read ON storage.objects;
CREATE POLICY driver_documents_owner_read ON storage.objects FOR SELECT
TO authenticated USING (
  bucket_id = 'driver-documents'
  AND (storage.foldername(name))[1] = auth.uid()::TEXT
);

CREATE OR REPLACE FUNCTION submit_driver_onboarding(
  p_display_name TEXT,
  p_contact TEXT,
  p_licence_path TEXT,
  p_selfie_path TEXT,
  p_make TEXT,
  p_model TEXT,
  p_color TEXT,
  p_body_type TEXT,
  p_plate_number TEXT,
  p_passenger_capacity INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plate TEXT := upper(regexp_replace(coalesce(p_plate_number, ''), '[[:space:]-]+', '', 'g'));
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  IF char_length(trim(coalesce(p_display_name, ''))) < 2
     OR char_length(trim(coalesce(p_contact, ''))) < 5
     OR p_licence_path = '' OR p_selfie_path = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'identity_fields_invalid');
  END IF;
  IF p_licence_path NOT LIKE auth.uid()::TEXT || '/%'
     OR p_selfie_path NOT LIKE auth.uid()::TEXT || '/%' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'document_path_not_owned');
  END IF;
  IF v_plate !~ '^[A-Z0-9]{3,12}$'
     OR p_passenger_capacity NOT BETWEEN 1 AND 6
     OR p_body_type NOT IN ('sedan', 'hatchback', 'mpv', 'suv') THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'vehicle_fields_invalid');
  END IF;

  INSERT INTO driver_verifications (
    driver_id, display_name, contact, licence_path, selfie_path,
    approval_status, rejection_reason, reviewed_by, reviewed_at, submitted_at, updated_at
  ) VALUES (
    auth.uid(), trim(p_display_name), trim(p_contact), p_licence_path, p_selfie_path,
    'pending', NULL, NULL, NULL, now(), now()
  ) ON CONFLICT (driver_id) DO UPDATE SET
    display_name = EXCLUDED.display_name,
    contact = EXCLUDED.contact,
    licence_path = EXCLUDED.licence_path,
    selfie_path = EXCLUDED.selfie_path,
    approval_status = 'pending', rejection_reason = NULL,
    reviewed_by = NULL, reviewed_at = NULL, submitted_at = now(), updated_at = now();

  INSERT INTO driver_vehicles (
    driver_id, make, model, color, body_type, plate_number,
    passenger_capacity, approval_status, rejection_reason, reviewed_by, reviewed_at, updated_at
  ) VALUES (
    auth.uid(), trim(p_make), trim(p_model), trim(p_color), p_body_type, v_plate,
    p_passenger_capacity, 'pending', NULL, NULL, NULL, now()
  ) ON CONFLICT (driver_id) DO UPDATE SET
    make = EXCLUDED.make, model = EXCLUDED.model, color = EXCLUDED.color,
    body_type = EXCLUDED.body_type, plate_number = EXCLUDED.plate_number,
    passenger_capacity = EXCLUDED.passenger_capacity,
    approval_status = 'pending', rejection_reason = NULL,
    reviewed_by = NULL, reviewed_at = NULL, updated_at = now();

  PERFORM set_config('response.headers', '[{"Content-Type":"application/json"}]', true);
  RETURN jsonb_build_object('success', TRUE, 'status', 'pending');
EXCEPTION WHEN unique_violation THEN
  RETURN jsonb_build_object('success', FALSE, 'reason', 'plate_already_registered');
END;
$$;

CREATE OR REPLACE FUNCTION get_my_driver_readiness()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'verification_status', coalesce(v.approval_status, 'missing'),
    'vehicle_status', coalesce(car.approval_status, 'missing'),
    'rejection_reason', coalesce(v.rejection_reason, car.rejection_reason),
    'vehicle', CASE WHEN car.driver_id IS NULL THEN NULL ELSE jsonb_build_object(
      'make', car.make, 'model', car.model, 'color', car.color,
      'body_type', car.body_type, 'plate_number', car.plate_number,
      'passenger_capacity', car.passenger_capacity,
      'approval_status', car.approval_status
    ) END
  )
  FROM (SELECT auth.uid() AS driver_id) me
  LEFT JOIN driver_verifications v ON v.driver_id = me.driver_id
  LEFT JOIN driver_vehicles car ON car.driver_id = me.driver_id;
$$;

-- Assigned passengers may see only the approved vehicle that is serving
-- their own active ride. This deliberately excludes licence/selfie paths,
-- contact details, reviewer data and every unassigned driver.
CREATE OR REPLACE VIEW driver_public_profiles
WITH (security_barrier = true)
AS
SELECT DISTINCT
  car.driver_id,
  verification.display_name AS name,
  car.make AS vehicle_make,
  car.model AS vehicle_model,
  car.color AS vehicle_color,
  car.body_type,
  car.plate_number,
  car.passenger_capacity
FROM driver_vehicles car
JOIN driver_verifications verification
  ON verification.driver_id = car.driver_id
JOIN rides assigned
  ON assigned.driver_id = car.driver_id
WHERE car.approval_status = 'approved'
  AND verification.approval_status = 'approved'
  AND assigned.status IN ('driver_assigned', 'en_route')
  AND (assigned.rider_id = auth.uid() OR car.driver_id = auth.uid());

REVOKE ALL ON driver_public_profiles FROM anon, authenticated;
GRANT SELECT ON driver_public_profiles TO authenticated;

CREATE OR REPLACE FUNCTION set_my_driver_offline()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE driver_presence
  SET is_online = FALSE, is_assigned = FALSE, last_seen_at = now()
  WHERE driver_id = auth.uid();
END;
$$;

-- Replace Kueh's compatible signature with a readiness-gated implementation.
CREATE OR REPLACE FUNCTION upsert_my_driver_presence(
  p_coarse_lat DOUBLE PRECISION,
  p_coarse_lng DOUBLE PRECISION,
  p_vehicle_categories TEXT[],
  p_is_online BOOLEAN,
  p_is_assigned BOOLEAN,
  p_heading DOUBLE PRECISION DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vehicle driver_vehicles%ROWTYPE;
  v_categories TEXT[];
BEGIN
  SELECT * INTO v_vehicle FROM driver_vehicles WHERE driver_id = auth.uid();
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'authentication_required'; END IF;
  IF p_is_online AND NOT EXISTS (
    SELECT 1 FROM driver_verifications verification
    WHERE verification.driver_id = auth.uid() AND verification.approval_status = 'approved'
  ) THEN RAISE EXCEPTION 'driver_verification_not_approved'; END IF;
  IF p_is_online AND (v_vehicle.driver_id IS NULL OR v_vehicle.approval_status != 'approved') THEN
    RAISE EXCEPTION 'vehicle_not_approved';
  END IF;
  IF p_coarse_lat NOT BETWEEN -90 AND 90 OR p_coarse_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'invalid_coordinates';
  END IF;

  v_categories := ARRAY['economy_4']::TEXT[];
  IF v_vehicle.passenger_capacity >= 2 THEN
    v_categories := array_append(v_categories, 'shared_economy');
  END IF;
  IF v_vehicle.passenger_capacity >= 6 THEN
    v_categories := array_append(v_categories, 'six_seater');
  END IF;

  INSERT INTO driver_presence (
    driver_id, anonymised_id, coarse_lat, coarse_lng, vehicle_categories,
    is_online, is_assigned, heading, last_seen_at
  ) VALUES (
    auth.uid(), 'V-' || upper(substr(md5(auth.uid()::TEXT || current_date::TEXT), 1, 8)),
    round(p_coarse_lat::numeric, 3), round(p_coarse_lng::numeric, 3),
    v_categories, p_is_online,
    EXISTS (
      SELECT 1 FROM rides active
      WHERE active.driver_id = auth.uid()
        AND active.status IN ('driver_assigned', 'en_route')
    ),
    p_heading, now()
  ) ON CONFLICT (driver_id) DO UPDATE SET
    coarse_lat = EXCLUDED.coarse_lat, coarse_lng = EXCLUDED.coarse_lng,
    vehicle_categories = EXCLUDED.vehicle_categories,
    is_online = EXCLUDED.is_online, is_assigned = EXCLUDED.is_assigned,
    heading = EXCLUDED.heading, last_seen_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION publish_assigned_driver_location(
  p_ride_id UUID,
  p_exact_lat DOUBLE PRECISION,
  p_exact_lng DOUBLE PRECISION,
  p_heading DOUBLE PRECISION DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plate TEXT;
BEGIN
  IF p_exact_lat NOT BETWEEN -90 AND 90 OR p_exact_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'invalid_coordinates';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM rides
    WHERE id = p_ride_id AND driver_id = auth.uid()
      AND status IN ('driver_assigned', 'en_route')
  ) THEN RAISE EXCEPTION 'ride_not_assigned'; END IF;
  SELECT plate_number INTO v_plate FROM driver_vehicles
  WHERE driver_id = auth.uid() AND approval_status = 'approved';
  IF v_plate IS NULL THEN RAISE EXCEPTION 'vehicle_not_approved'; END IF;

  INSERT INTO assigned_driver_location (
    ride_id, driver_id, exact_lat, exact_lng, vehicle_plate, heading, seen_at
  ) VALUES (
    p_ride_id, auth.uid(), p_exact_lat, p_exact_lng, v_plate, p_heading, now()
  ) ON CONFLICT (ride_id) DO UPDATE SET
    driver_id = EXCLUDED.driver_id, exact_lat = EXCLUDED.exact_lat,
    exact_lng = EXCLUDED.exact_lng, vehicle_plate = EXCLUDED.vehicle_plate,
    heading = EXCLUDED.heading, seen_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION accept_available_ride(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride rides%ROWTYPE;
  v_vehicle driver_vehicles%ROWTYPE;
BEGIN
  SELECT * INTO v_vehicle FROM driver_vehicles WHERE driver_id = auth.uid() FOR UPDATE;
  IF NOT EXISTS (SELECT 1 FROM driver_verifications WHERE driver_id = auth.uid() AND approval_status = 'approved')
     OR v_vehicle.driver_id IS NULL OR v_vehicle.approval_status != 'approved' THEN
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
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_found'); END IF;
  IF v_ride.driver_id IS NOT NULL OR v_ride.status != 'requested' OR v_ride.group_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_available');
  END IF;
  IF v_ride.rider_id = auth.uid() THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_cannot_accept_own_ride');
  END IF;
  IF v_vehicle.passenger_capacity < v_ride.passenger_count
     OR (v_ride.service_type = 'six_seater' AND v_vehicle.passenger_capacity < 6) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'vehicle_capacity_incompatible');
  END IF;

  UPDATE rides SET driver_id = auth.uid(), status = 'driver_assigned',
    accepted_at = now(), free_cancel_until = now() + INTERVAL '2 minutes'
  WHERE id = p_ride_id;
  UPDATE driver_presence SET is_assigned = TRUE WHERE driver_id = auth.uid();
  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id);
END;
$$;

-- Strengthen Kueh's group claim with driver approval, capacity and cancellation timestamps.
CREATE OR REPLACE FUNCTION accept_carpool_group(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group ride_groups%ROWTYPE;
  v_vehicle driver_vehicles%ROWTYPE;
BEGIN
  SELECT * INTO v_vehicle FROM driver_vehicles WHERE driver_id = auth.uid() FOR UPDATE;
  IF NOT EXISTS (SELECT 1 FROM driver_verifications WHERE driver_id = auth.uid() AND approval_status = 'approved')
     OR v_vehicle.driver_id IS NULL OR v_vehicle.approval_status != 'approved' THEN
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
  SELECT * INTO v_group FROM ride_groups WHERE id = p_group_id FOR UPDATE;
  IF v_group.id IS NULL THEN RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_found'); END IF;
  IF v_group.status != 'matched' OR v_group.driver_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_available');
  END IF;
  IF v_vehicle.passenger_capacity < v_group.total_passengers THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'vehicle_capacity_incompatible');
  END IF;
  IF EXISTS (SELECT 1 FROM ride_group_members WHERE group_id = v_group.id AND rider_id = auth.uid()) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_cannot_accept_own_group');
  END IF;

  UPDATE ride_groups SET driver_id = auth.uid(), status = 'driver_assigned' WHERE id = v_group.id;
  UPDATE rides SET driver_id = auth.uid(), status = 'driver_assigned',
    accepted_at = now(), free_cancel_until = now() + INTERVAL '2 minutes'
  WHERE id IN (SELECT ride_id FROM ride_group_members WHERE group_id = v_group.id);
  UPDATE driver_presence SET is_assigned = TRUE WHERE driver_id = auth.uid();
  RETURN jsonb_build_object('success', TRUE, 'group_id', v_group.id);
END;
$$;

CREATE OR REPLACE FUNCTION transition_driver_ride(
  p_ride_id UUID,
  p_next_status TEXT,
  p_cancellation_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride rides%ROWTYPE;
BEGIN
  SELECT * INTO v_ride FROM rides
  WHERE id = p_ride_id AND driver_id = auth.uid() FOR UPDATE;
  IF v_ride.id IS NULL THEN RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_assigned'); END IF;
  IF NOT ((v_ride.status = 'driver_assigned' AND p_next_status IN ('en_route', 'cancelled'))
       OR (v_ride.status = 'en_route' AND p_next_status IN ('completed', 'cancelled'))) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_transition');
  END IF;
  IF p_next_status = 'cancelled' AND char_length(trim(coalesce(p_cancellation_reason, ''))) < 3 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'cancellation_reason_required');
  END IF;

  IF v_ride.group_id IS NULL THEN
    UPDATE rides SET status = p_next_status,
      completed_at = CASE WHEN p_next_status = 'completed' THEN now() ELSE completed_at END,
      cancelled_at = CASE WHEN p_next_status = 'cancelled' THEN now() ELSE cancelled_at END,
      cancellation_reason = CASE WHEN p_next_status = 'cancelled' THEN trim(p_cancellation_reason) ELSE cancellation_reason END
    WHERE id = v_ride.id;
  ELSE
    UPDATE ride_groups SET status = p_next_status,
      completed_at = CASE WHEN p_next_status = 'completed' THEN now() ELSE completed_at END,
      cancelled_at = CASE WHEN p_next_status = 'cancelled' THEN now() ELSE cancelled_at END
    WHERE id = v_ride.group_id AND driver_id = auth.uid();
    UPDATE rides SET status = p_next_status,
      completed_at = CASE WHEN p_next_status = 'completed' THEN now() ELSE completed_at END,
      cancelled_at = CASE WHEN p_next_status = 'cancelled' THEN now() ELSE cancelled_at END,
      cancellation_reason = CASE WHEN p_next_status = 'cancelled' THEN trim(p_cancellation_reason) ELSE cancellation_reason END
    WHERE group_id = v_ride.group_id AND driver_id = auth.uid();
  END IF;
  IF p_next_status IN ('completed', 'cancelled') THEN
    UPDATE driver_presence SET is_assigned = FALSE WHERE driver_id = auth.uid();
    DELETE FROM assigned_driver_location WHERE driver_id = auth.uid();
  END IF;
  RETURN jsonb_build_object('success', TRUE, 'status', p_next_status);
END;
$$;

REVOKE ALL ON FUNCTION submit_driver_onboarding(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION get_my_driver_readiness() FROM PUBLIC;
REVOKE ALL ON FUNCTION set_my_driver_offline() FROM PUBLIC;
REVOKE ALL ON FUNCTION publish_assigned_driver_location(UUID,DOUBLE PRECISION,DOUBLE PRECISION,DOUBLE PRECISION) FROM PUBLIC;
REVOKE ALL ON FUNCTION accept_available_ride(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION accept_carpool_group(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION transition_driver_ride(UUID,TEXT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION submit_driver_onboarding(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_my_driver_readiness() TO authenticated;
GRANT EXECUTE ON FUNCTION set_my_driver_offline() TO authenticated;
GRANT EXECUTE ON FUNCTION publish_assigned_driver_location(UUID,DOUBLE PRECISION,DOUBLE PRECISION,DOUBLE PRECISION) TO authenticated;
GRANT EXECUTE ON FUNCTION accept_available_ride(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION accept_carpool_group(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION transition_driver_ride(UUID,TEXT,TEXT) TO authenticated;


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260903000000_t_rewards_earn.sql
-- --------------------------------------------------------------------------
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


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260904000000_t_admin_policies_rating_anon.sql
-- --------------------------------------------------------------------------
-- InfraGo Tey module T3+T4+T6: admin role check, RLS for Heng's review
-- tables, anonymous driver feedback view, and admin moderation of ratings.
-- Owned by Tey; base driver/vehicle tables owned by Heng (H1, H2 migrations).

-- ---------------------------------------------------------------------------
-- Helper: current_user_is_admin reads profiles.role
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- T3 Admin Identity Review (Heng's driver_verifications table)
--   driver: read own submission only
--   admin:  read pending queue, approve or reject with reason
--   reviewer cannot approve own submissions (checked in RPC)
--   RLS policies here apply ON TOP OF whatever base RLS Heng already set.
--   We recreate with OR REPLACE semantics using CREATE OR REPLACE is not
--   possible on POLICY, so we DROP IF EXISTS then CREATE.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- T3 Admin Identity Review RPCs
--   approve_driver_verification / reject_driver_verification
--   Sets reviewed_by / reviewed_at / status and enforces "cannot review self"
--   Requires reason on reject. Uses SECURITY DEFINER so RLS update policy is
--   a secondary backstop, not the only gate.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- T4 Admin Vehicle Review (Heng's driver_vehicles table)
--   driver: read/write own submission
--   admin:  approve or reject with reason
--   6-seater gate done inside approve RPC: capacity must be >=6
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- T6 Driver anonymous feedback view
--   Drivers see tags/comment/score only, no rider identity.
--   RLS on base table already prevents direct SELECT by driver.
--   security_barrier prevents predicate pushdown / leaking rider_id.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- T6 Admin moderation of a single rating record
--   Only admins can soft-remove individual records.
--   Coursework prototype: we delete the row outright (no live-user scale).
-- ---------------------------------------------------------------------------
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


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260905000000_t_sdg_analytics.sql
-- --------------------------------------------------------------------------
-- InfraGo Tey module T7: SDG and operational analytics computed from real
-- ride/group/payment data, aggregated server-side so no rider/driver RLS
-- row is ever exposed individually. Read-only, no private transaction
-- detail (no ride_id/payer_id) leaves this function.

CREATE OR REPLACE FUNCTION sdg_operational_analytics(
  p_start TIMESTAMPTZ DEFAULT NULL,
  p_end TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start TIMESTAMPTZ := COALESCE(p_start, '-infinity'::timestamptz);
  v_end TIMESTAMPTZ := COALESCE(p_end, 'infinity'::timestamptz);
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  IF p_start IS NOT NULL AND p_end IS NOT NULL AND p_start > p_end THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_date_range');
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'range', jsonb_build_object('start', p_start, 'end', p_end),

    'sdg', (
      SELECT jsonb_build_object(
        'completed_rides', COUNT(*) FILTER (WHERE r.status = 'completed'),
        'transit_linked_rides', COUNT(*) FILTER (
          WHERE r.status = 'completed' AND r.transit_stop_id IS NOT NULL
        )
      )
      FROM rides r
      WHERE r.completed_at BETWEEN v_start AND v_end
    ) || (
      SELECT jsonb_build_object(
        'shared_groups_completed', COUNT(*),
        'avg_passengers_per_vehicle', ROUND(AVG(GREATEST(g.total_passengers, 0))::numeric, 2),
        'vehicle_km_avoided', ROUND(COALESCE(SUM(GREATEST(COALESCE(g.vehicle_km_avoided, 0), 0)), 0)::numeric, 1)
      )
      FROM ride_groups g
      WHERE g.status = 'completed' AND g.completed_at BETWEEN v_start AND v_end
    ) || jsonb_build_object(
      'avg_rider_detour_ratio', (
        SELECT ROUND((AVG(GREATEST(m.detour_percent, 0)) / 100.0)::numeric, 4)
        FROM ride_group_members m
        JOIN ride_groups g ON g.id = m.group_id
        WHERE g.status = 'completed' AND g.completed_at BETWEEN v_start AND v_end
      ),
      -- Savings = economy-equivalent solo fare (fare_quotes.solo_amount, which
      -- is always populated) minus what was actually charged for the shared
      -- ride. Clamped at 0 so a bad/negative imported fare never shows a loss.
      'estimated_savings_myr', (
        SELECT ROUND(COALESCE(SUM(GREATEST(
          COALESCE(lq.solo_amount, 0) - COALESCE(p.final_amount, lq.shared_amount, lq.solo_amount, 0),
          0
        )), 0)::numeric, 2)
        FROM rides r
        JOIN LATERAL (
          SELECT fq.solo_amount, fq.shared_amount
          FROM fare_quotes fq
          WHERE fq.ride_id = r.id
          ORDER BY fq.quoted_at DESC
          LIMIT 1
        ) lq ON TRUE
        LEFT JOIN payments p ON p.ride_id = r.id AND p.status = 'paid'
        WHERE r.status = 'completed' AND r.group_id IS NOT NULL
          AND r.completed_at BETWEEN v_start AND v_end
      )
    ),

    'vehicle_capacity_distribution', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('capacity', v.passenger_capacity, 'count', v.n) ORDER BY v.passenger_capacity)
      FROM (
        SELECT passenger_capacity, COUNT(*) AS n
        FROM driver_vehicles
        WHERE approval_status = 'approved'
        GROUP BY passenger_capacity
      ) v
    ), '[]'::jsonb),

    'service_category_distribution', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('service_type', s.service_type, 'count', s.n) ORDER BY s.service_type)
      FROM (
        SELECT service_type, COUNT(*) AS n
        FROM rides
        WHERE status = 'completed' AND completed_at BETWEEN v_start AND v_end
        GROUP BY service_type
      ) s
    ), '[]'::jsonb),

    'cancellations', (
      SELECT jsonb_build_object(
        'cancelled_count', COUNT(*) FILTER (
          WHERE r.status = 'cancelled' AND r.cancelled_at BETWEEN v_start AND v_end
        ),
        'completed_count', (
          SELECT COUNT(*) FROM rides WHERE status = 'completed' AND completed_at BETWEEN v_start AND v_end
        ),
        'free_cancellation_count', COUNT(*) FILTER (
          WHERE r.status = 'cancelled' AND r.cancelled_at BETWEEN v_start AND v_end
            AND COALESCE(r.cancellation_fee, 0) <= 0
        ),
        'fee_cancellation_count', COUNT(*) FILTER (
          WHERE r.status = 'cancelled' AND r.cancelled_at BETWEEN v_start AND v_end
            AND COALESCE(r.cancellation_fee, 0) > 0
        )
      )
      FROM rides r
    ) || jsonb_build_object(
      'top_reasons', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('reason', t.reason, 'count', t.n))
        FROM (
          SELECT cancellation_reason AS reason, COUNT(*) AS n
          FROM rides
          WHERE status = 'cancelled' AND cancelled_at BETWEEN v_start AND v_end
            AND cancellation_reason IS NOT NULL AND trim(cancellation_reason) <> ''
          GROUP BY cancellation_reason
          ORDER BY COUNT(*) DESC
          LIMIT 5
        ) t
      ), '[]'::jsonb),
      'prototype_driver_compensation_myr', COALESCE((
        SELECT ROUND(SUM(GREATEST(driver_compensation_amount, 0))::numeric, 2)
        FROM payments
        WHERE created_at BETWEEN v_start AND v_end
          AND driver_compensation_amount > 0
      ), 0)
    ),

    -- Aggregate counts/totals only: no ride_id, payer_id or other per-user
    -- transaction detail leaves this function.
    'payments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'method', x.method, 'status', x.status, 'count', x.n, 'total_myr', x.total
      ) ORDER BY x.method, x.status)
      FROM (
        SELECT method, status, COUNT(*) AS n,
          ROUND(SUM(GREATEST(COALESCE(final_amount, quoted_amount, 0), 0))::numeric, 2) AS total
        FROM payments
        WHERE created_at BETWEEN v_start AND v_end
        GROUP BY method, status
      ) x
    ), '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION sdg_operational_analytics(TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sdg_operational_analytics(TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260906000000_t_backfill_orphan_ride_payments.sql
-- --------------------------------------------------------------------------
-- InfraGo Tey module: one-off data backfill.
--
-- The app's only ride-creation path (create_ride_with_quote_and_payment in
-- 20260829000000_f_payments_wallet.sql) always inserts a `payments` row
-- atomically alongside the `rides` row, so a ride cannot reach 'completed'
-- through normal app usage without ever having a payment. A completed ride
-- with zero payment rows was inserted directly (e.g. via the Studio table
-- editor) to test driver/admin/rating flows in isolation, bypassing that
-- RPC. This is not a code bug - it only backfills a plausible 'paid' cash
-- payment for any such orphaned completed ride, so downstream reporting
-- (this module's SDG/payment analytics) reflects a complete, consistent
-- record instead of a silent gap.
--
-- Scope is narrow and safe to re-run: only rides with status = 'completed'
-- AND zero existing payments rows are touched. idempotency_key is
-- deterministic per ride and unique-constrained, so re-running this file
-- is a no-op the second time (ON CONFLICT DO NOTHING).

INSERT INTO payments (
  ride_id, group_id, payer_id, method, status, idempotency_key,
  quoted_amount, discount_amount, reward_points_redeemed,
  cancellation_fee, refunded_amount, driver_compensation_amount,
  final_amount, currency, created_at, updated_at
)
SELECT
  r.id,
  r.group_id,
  r.rider_id,
  'cash',
  'paid',
  'backfill-orphan-payment-' || r.id::text,
  amt.v_amount,
  0,
  0,
  0,
  0,
  0,
  amt.v_amount,
  'MYR',
  COALESCE(r.completed_at, r.departure_time, now()),
  COALESCE(r.completed_at, r.departure_time, now())
FROM rides r
CROSS JOIN LATERAL (
  SELECT COALESCE(
    (
      SELECT CASE
        WHEN fq.service_type = 'shared_economy' AND r.group_id IS NOT NULL
          THEN COALESCE(fq.shared_amount, fq.solo_amount)
        ELSE fq.solo_amount
      END
      FROM fare_quotes fq
      WHERE fq.ride_id = r.id
      ORDER BY fq.quoted_at DESC
      LIMIT 1
    ),
    r.estimated_shared_fare,
    r.estimated_solo_fare,
    0
  ) AS v_amount
) amt
WHERE r.status = 'completed'
  AND NOT EXISTS (SELECT 1 FROM payments p WHERE p.ride_id = r.id)
ON CONFLICT (idempotency_key) DO NOTHING;


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260907000000_t_driver_vehicles_service_eligibility.sql
-- --------------------------------------------------------------------------
-- InfraGo Tey module: fix missing driver_vehicles.service_eligibility.
--
-- docs/team/README.md's shared contract has always listed this column, and
-- both approve_driver_vehicle() (20260904000000_t_admin_policies_rating_anon.sql)
-- and PendingVehicleSubmission (lib/tey/admin_review_repository.dart) read it
-- from driver_vehicles - but no migration ever created it, so approving a
-- vehicle (and loading the admin vehicle queue) fails at runtime with
-- "column driver_vehicles.service_eligibility does not exist".
--
-- Heng's submit_driver_onboarding() never asked drivers to pick a service
-- category separately - passenger_capacity is the only real signal, and
-- upsert_my_driver_presence() already derives ride-matching categories from
-- it (economy_4 always; + shared_economy at capacity >= 2; + six_seater at
-- capacity >= 6). A GENERATED column applies that exact same derivation,
-- so it is always consistent with passenger_capacity by construction, is
-- backfilled automatically for existing rows by the ALTER TABLE itself, and
-- needs no change to submit_driver_onboarding's INSERT/UPSERT.
ALTER TABLE driver_vehicles
  ADD COLUMN IF NOT EXISTS service_eligibility TEXT[]
  GENERATED ALWAYS AS (
    CASE
      WHEN passenger_capacity >= 6 THEN ARRAY['economy_4', 'shared_economy', 'six_seater']
      WHEN passenger_capacity >= 2 THEN ARRAY['economy_4', 'shared_economy']
      ELSE ARRAY['economy_4']
    END
  ) STORED;


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260908000000_t_profiles_admin_role.sql
-- --------------------------------------------------------------------------
-- InfraGo Tey module: allow 'admin' in profiles.role.
--
-- current_user_is_admin() and every admin RLS policy added in
-- 20260904000000_t_admin_policies_rating_anon.sql check
-- lower(profiles.role::text) = 'admin', but profiles_role_check (defined
-- outside this repo's migrations, alongside the base profiles table) only
-- ever allowed ('commuter', 'driver'). No profile row could legally hold
-- role = 'admin', so the entire admin review module (T3 identity review,
-- T4 vehicle review) was structurally unreachable - not one account could
-- ever pass current_user_is_admin(), independent of any other bug.
--
-- Widening an existing CHECK constraint to add one more allowed value is
-- safe: every existing row is already 'commuter' or 'driver' and stays
-- valid; this only permits a new value going forward.
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE profiles ADD CONSTRAINT profiles_role_check
  CHECK (role = ANY (ARRAY['commuter'::text, 'driver'::text, 'admin'::text]));


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/20260909000000_t_fix_driver_verifications_status_column.sql
-- --------------------------------------------------------------------------
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


-- --------------------------------------------------------------------------
-- Source: supabase/migrations/2026091000000_h_p0_driver_enhancements.sql
-- --------------------------------------------------------------------------
-- =====================================================================
-- Migration: 2026091000000_h_p0_driver_enhancements.sql
-- Module:    HENG (Driver Operations)
-- Scope:     P0 Demo blocker fixes + driver stepwise progression +
--            rides table safety net (RLS + indexes)
-- =====================================================================

-- *********************************************************************
-- P0-5a: BUG FIX — free_cancel_until grace period must be 3 minutes
--        (mismatch: Foo CancellationPolicy.gracePeriod = 3 min but
--         Heng's accept RPC wrote 2 min -> wrong boundary behavior)
-- *********************************************************************

CREATE OR REPLACE FUNCTION accept_available_ride(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_ride rides%ROWTYPE;
  v_vehicle driver_vehicles%ROWTYPE;
  v_presence driver_presence%ROWTYPE;
  v_summary JSONB;
  v_categories TEXT[];
BEGIN
  SELECT * INTO v_presence FROM driver_presence WHERE driver_id = v_driver_id FOR UPDATE;
  IF v_presence.driver_id IS NULL OR v_presence.is_online IS FALSE THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_not_online');
  END IF;
  IF v_presence.last_seen_at IS NULL OR
     v_presence.last_seen_at < now() - INTERVAL '30 seconds' THEN
    UPDATE driver_presence SET is_online = FALSE WHERE driver_id = v_driver_id;
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_not_online');
  END IF;
  IF v_presence.accepted_ride_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_has_active_ride');
  END IF;

  SELECT * INTO v_vehicle FROM driver_vehicles WHERE driver_id = v_driver_id;
  IF v_vehicle.driver_id IS NULL OR v_vehicle.approval_status != 'approved' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'vehicle_not_approved');
  END IF;

  v_categories := ARRAY['economy_4']::TEXT[];
  IF v_vehicle.vehicle_type IN ('suv', 'mpv') OR v_vehicle.passenger_capacity >= 6 THEN
    v_categories := array_append(v_categories, 'shared_economy');
  END IF;
  IF v_vehicle.passenger_capacity >= 6 THEN
    v_categories := array_append(v_categories, 'six_seater');
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_found');
  END IF;
  IF v_ride.driver_id IS NOT NULL OR v_ride.status != 'requested' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_not_available');
  END IF;
  IF NOT array_to_string(v_categories, ',') LIKE '%' || v_ride.service_type || '%' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'service_category_ineligible');
  END IF;
  IF v_vehicle.passenger_capacity < v_ride.passenger_count THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'vehicle_capacity_exceeded');
  END IF;
  IF v_ride.requested_at IS NOT NULL AND
     v_ride.requested_at < now() - INTERVAL '10 minutes' THEN
    UPDATE rides SET status = 'expired' WHERE id = v_ride.id;
    RETURN jsonb_build_object('success', FALSE, 'reason', 'ride_expired');
  END IF;

  UPDATE rides SET
    driver_id = v_driver_id,
    driver_plate = v_vehicle.plate_number,
    status = 'driver_assigned',
    accepted_at = now(),
    free_cancel_until = now() + INTERVAL '3 minutes'
  WHERE id = v_ride.id;

  UPDATE driver_presence
    SET accepted_ride_id = v_ride.id, is_online = TRUE
    WHERE driver_id = v_driver_id;

  v_summary := jsonb_build_object(
    'success', TRUE,
    'ride_id', v_ride.id,
    'status', 'driver_assigned',
    'driver_name', (SELECT name FROM profiles WHERE id = v_driver_id),
    'driver_rating', (SELECT COALESCE(avg_driver_rating, 0) FROM driver_public_profiles dp WHERE dp.driver_id = v_driver_id),
    'driver_rating_count', (SELECT COALESCE(rating_count, 0) FROM driver_public_profiles dp WHERE dp.driver_id = v_driver_id),
    'vehicle_make', v_vehicle.make,
    'vehicle_model', v_vehicle.model,
    'vehicle_colour', v_vehicle.vehicle_colour,
    'vehicle_type', v_vehicle.vehicle_type,
    'vehicle_plate', v_vehicle.plate_number,
    'vehicle_capacity', v_vehicle.passenger_capacity,
    'accepted_at', now(),
    'free_cancel_until', now() + INTERVAL '3 minutes'
  );

  PERFORM pg_notify('ride:' || v_ride.id::TEXT, v_summary::TEXT);
  RETURN v_summary;
END;
$$;

CREATE OR REPLACE FUNCTION accept_carpool_group(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_group ride_groups%ROWTYPE;
  v_vehicle driver_vehicles%ROWTYPE;
  v_presence driver_presence%ROWTYPE;
  v_summary JSONB;
  v_categories TEXT[];
  v_rider_count INTEGER;
BEGIN
  SELECT * INTO v_presence FROM driver_presence WHERE driver_id = v_driver_id FOR UPDATE;
  IF v_presence.driver_id IS NULL OR v_presence.is_online IS FALSE THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_not_online');
  END IF;
  IF v_presence.last_seen_at IS NULL OR
     v_presence.last_seen_at < now() - INTERVAL '30 seconds' THEN
    UPDATE driver_presence SET is_online = FALSE WHERE driver_id = v_driver_id;
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_not_online');
  END IF;
  IF v_presence.accepted_ride_id IS NOT NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'driver_has_active_ride');
  END IF;

  SELECT * INTO v_vehicle FROM driver_vehicles WHERE driver_id = v_driver_id;
  IF v_vehicle.driver_id IS NULL OR v_vehicle.approval_status != 'approved' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'vehicle_not_approved');
  END IF;
  IF NOT (v_vehicle.vehicle_type IN ('suv', 'mpv') OR v_vehicle.passenger_capacity >= 6) THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'service_category_ineligible');
  END IF;

  SELECT * INTO v_group FROM ride_groups WHERE id = p_group_id FOR UPDATE;
  IF v_group.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_found');
  END IF;
  IF v_group.driver_id IS NOT NULL OR v_group.status != 'ready_to_match' THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_available');
  END IF;

  SELECT count(*) INTO v_rider_count
    FROM ride_group_members m WHERE m.group_id = v_group.id;
  IF v_rider_count < 2 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_needs_more_members');
  END IF;
  IF v_group.total_passengers > v_vehicle.passenger_capacity THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'vehicle_capacity_exceeded');
  END IF;

  UPDATE ride_groups SET
    driver_id = v_driver_id,
    status = 'driver_assigned'
  WHERE id = v_group.id;

  UPDATE rides SET
    driver_id = v_driver_id,
    driver_plate = v_vehicle.plate_number,
    status = 'driver_assigned',
    accepted_at = now(),
    free_cancel_until = now() + INTERVAL '3 minutes'
  WHERE group_id = v_group.id;

  UPDATE driver_presence
    SET accepted_group_id = v_group.id, is_online = TRUE
    WHERE driver_id = v_driver_id;

  v_summary := jsonb_build_object(
    'success', TRUE,
    'group_id', v_group.id,
    'status', 'driver_assigned',
    'driver_name', (SELECT name FROM profiles WHERE id = v_driver_id),
    'driver_rating', (SELECT COALESCE(avg_driver_rating, 0) FROM driver_public_profiles dp WHERE dp.driver_id = v_driver_id),
    'driver_rating_count', (SELECT COALESCE(rating_count, 0) FROM driver_public_profiles dp WHERE dp.driver_id = v_driver_id),
    'vehicle_make', v_vehicle.make,
    'vehicle_model', v_vehicle.model,
    'vehicle_colour', v_vehicle.vehicle_colour,
    'vehicle_type', v_vehicle.vehicle_type,
    'vehicle_plate', v_vehicle.plate_number,
    'vehicle_capacity', v_vehicle.passenger_capacity,
    'accepted_at', now(),
    'free_cancel_until', now() + INTERVAL '3 minutes'
  );

  PERFORM pg_notify('ride_group:' || v_group.id::TEXT, v_summary::TEXT);
  RETURN v_summary;
END;
$$;

REVOKE ALL ON FUNCTION accept_available_ride(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION accept_carpool_group(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION accept_available_ride(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION accept_carpool_group(UUID) TO authenticated;


-- *********************************************************************
-- P0-2: Ride group stepwise progression (pickup/dropoff stops)
-- *********************************************************************

ALTER TABLE ride_groups
  ADD COLUMN IF NOT EXISTS current_stop_idx INTEGER
    CHECK (current_stop_idx IS NULL OR current_stop_idx BETWEEN 0 AND 3);

ALTER TABLE ride_groups
  ADD COLUMN IF NOT EXISTS stop_arrived_at TIMESTAMPTZ[];

COMMENT ON COLUMN ride_groups.current_stop_idx IS
  '0..3 index into optimised_stop_order; NULL before first advance. '
  'Convention: stops 0 and 1 are pickups (P1, P2), stops 2 and 3 are dropoffs (D1, D2).';
COMMENT ON COLUMN ride_groups.stop_arrived_at IS
  'One arrival timestamp appended per successful advance_group_stop_pointer call.';


CREATE OR REPLACE FUNCTION advance_group_stop_pointer(p_group_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group ride_groups%ROWTYPE;
  v_next_idx INTEGER;
  v_is_pickup BOOLEAN;
BEGIN
  SELECT * INTO v_group FROM ride_groups WHERE id = p_group_id FOR UPDATE;
  IF v_group.id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'group_not_found');
  END IF;
  IF v_group.driver_id IS NULL OR v_group.driver_id != auth.uid() THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_assigned_driver');
  END IF;
  IF v_group.status NOT IN ('driver_assigned', 'en_route') THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_in_progress');
  END IF;

  v_next_idx := COALESCE(v_group.current_stop_idx, -1) + 1;
  IF v_next_idx > 3 THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'all_stops_done');
  END IF;

  -- Once we have made any progress -> promote both group and rides to en_route.
  IF v_group.status = 'driver_assigned' THEN
    UPDATE ride_groups SET status = 'en_route' WHERE id = v_group.id;
    UPDATE rides SET status = 'en_route' WHERE group_id = v_group.id;
  END IF;

  UPDATE ride_groups SET
    current_stop_idx = v_next_idx,
    stop_arrived_at = CASE
      WHEN stop_arrived_at IS NULL THEN ARRAY[now()]::TIMESTAMPTZ[]
      ELSE array_append(stop_arrived_at, now())
    END
  WHERE id = v_group.id;

  v_is_pickup := (v_next_idx < 2);

  RETURN jsonb_build_object(
    'success', TRUE,
    'current_stop_idx', v_next_idx,
    'is_pickup_stop', v_is_pickup,
    'remaining_stops', 3 - v_next_idx,
    'group_status', 'en_route'
  );
END;
$$;

REVOKE ALL ON FUNCTION advance_group_stop_pointer(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION advance_group_stop_pointer(UUID) TO authenticated;


-- *********************************************************************
-- C-1: Missing indexes on rides (driver-side lookups + streaming)
-- *********************************************************************

CREATE INDEX IF NOT EXISTS idx_rides_driver_id_status
  ON rides(driver_id, status) WHERE driver_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_rides_group_id
  ON rides(group_id) WHERE group_id IS NOT NULL;


-- *********************************************************************
-- C-2: rides table RLS (critical safety net - was missing entirely)
--      All driver-side mutations remain gated behind SECURITY DEFINER
--      RPCs (accept_* / transition_* / cancel_ride_and_settle_* etc.)
--      so the policies below intentionally give no direct UPDATE to
--      drivers.
-- *********************************************************************

ALTER TABLE rides ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rides_participant_select ON rides;
CREATE POLICY rides_participant_select ON rides FOR SELECT TO authenticated
USING (
  rider_id = auth.uid()
  OR driver_id = auth.uid()
  OR EXISTS (
    SELECT 1 FROM ride_group_members gm
    WHERE gm.ride_id = rides.id AND gm.rider_id = auth.uid()
  )
);

DROP POLICY IF EXISTS rides_rider_insert ON rides;
CREATE POLICY rides_rider_insert ON rides FOR INSERT TO authenticated
WITH CHECK (rider_id = auth.uid());

DROP POLICY IF EXISTS rides_rider_update_preassign ON rides;
CREATE POLICY rides_rider_update_preassign ON rides FOR UPDATE TO authenticated
USING (
  rider_id = auth.uid()
  AND driver_id IS NULL
  AND status NOT IN ('completed', 'cancelled', 'expired')
)
WITH CHECK (
  rider_id = auth.uid()
  AND driver_id IS NULL
  AND status NOT IN ('completed', 'cancelled', 'expired')
);


