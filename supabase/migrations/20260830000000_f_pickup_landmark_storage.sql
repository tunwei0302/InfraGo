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
