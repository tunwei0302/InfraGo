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
