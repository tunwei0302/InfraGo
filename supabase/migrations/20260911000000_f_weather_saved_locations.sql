CREATE TABLE IF NOT EXISTS weather_saved_locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  label TEXT NOT NULL CHECK (char_length(trim(label)) BETWEEN 1 AND 40),
  latitude DOUBLE PRECISION NOT NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude DOUBLE PRECISION NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_weather_saved_locations_user
  ON weather_saved_locations(user_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_weather_saved_locations_user_label
  ON weather_saved_locations(user_id, lower(label));

ALTER TABLE weather_saved_locations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS weather_saved_locations_owner_select ON weather_saved_locations;
CREATE POLICY weather_saved_locations_owner_select ON weather_saved_locations
FOR SELECT TO authenticated USING (user_id = auth.uid());

DROP POLICY IF EXISTS weather_saved_locations_owner_insert ON weather_saved_locations;
CREATE POLICY weather_saved_locations_owner_insert ON weather_saved_locations
FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS weather_saved_locations_owner_update ON weather_saved_locations;
CREATE POLICY weather_saved_locations_owner_update ON weather_saved_locations
FOR UPDATE TO authenticated
USING (user_id = auth.uid())
WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS weather_saved_locations_owner_delete ON weather_saved_locations;
CREATE POLICY weather_saved_locations_owner_delete ON weather_saved_locations
FOR DELETE TO authenticated USING (user_id = auth.uid());
