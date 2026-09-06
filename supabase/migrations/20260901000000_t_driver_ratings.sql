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
