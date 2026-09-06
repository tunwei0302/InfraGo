ALTER TABLE driver_vehicles
  ADD COLUMN IF NOT EXISTS service_eligibility TEXT[]
  GENERATED ALWAYS AS (
    CASE
      WHEN passenger_capacity >= 6 THEN ARRAY['economy_4', 'shared_economy', 'six_seater']
      WHEN passenger_capacity >= 2 THEN ARRAY['economy_4', 'shared_economy']
      ELSE ARRAY['economy_4']
    END
  ) STORED;
