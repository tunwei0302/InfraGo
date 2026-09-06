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
