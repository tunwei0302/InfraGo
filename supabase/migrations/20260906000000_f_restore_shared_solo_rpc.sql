-- Deployment repair: the original Foo payment migration was applied before
-- continue_shared_ride_solo was appended to that already-used timestamp.
-- Re-declare the same RPC in a new migration so existing projects receive it.
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
    RETURN jsonb_build_object(
      'success', FALSE,
      'reason', 'pending_quote_or_payment_not_found'
    );
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

REVOKE ALL ON FUNCTION continue_shared_ride_solo(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION continue_shared_ride_solo(UUID) TO authenticated;
