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
