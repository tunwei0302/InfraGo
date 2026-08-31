# Kueh Jian Wei Module — Implementation and Acceptance Status

Last verified: 2026-08-31

## Outcome

Kueh's commuter-facing MVP code is implemented and builds successfully. It
covers the map journey from pickup and destination selection through routing,
vehicle selection, shared matching, assigned-driver tracking, cancellation,
receipt and the rating entry point.

Verification on the current working tree:

- `flutter analyze`: no issues.
- `flutter test`: 185 tests passed.
- `flutter build apk --debug`: passed.
- APK: `build/app/outputs/flutter-apk/app-debug.apk`.

This does not mean the shared Supabase project is already configured. Database
migrations still have to be reviewed and applied in order, and the three-account
demo depends on Heng, Foo and Tey completing their integration contracts.

## Implemented in Kueh's Module

### Bolt-style trip planner and map

- GPS current-location pickup with permission/error handling.
- Photon pickup and destination search, reverse geocoding and stale-response
  protection.
- Tap-to-place pickup/destination pins.
- OSM map with required attribution.
- OSRM road geometry, route distance, ETA, camera fitting and error handling.
- Explicit trip lifecycle:
  `explore -> routePreview -> vehicleOptions -> pickupConfirmation -> searchingDriver -> driverAssigned -> enRoute -> completed/cancelled`.
- Economy, Shared Economy and SUV/6-seater selection supplied with Foo's fare
  quote and checkout flow.
- Passenger-count and booking-time rules.
- Pickup note and optional landmark-photo handoff.

### Nearby and assigned vehicles

- Reads anonymised coarse vehicles from `nearby_driver_presence` before a ride
  is assigned.
- Filters offline, assigned, stale, incompatible and out-of-radius entries.
- Never exposes driver id, plate number or exact location before assignment.
- Shows exact participant-protected driver location only after assignment.
- Assigned-driver panel includes ETA, vehicle details, rating, cancellation and
  Contact Driver.

### Official transit connection

- Reads Tey's `transit_stops` data through `TransitStopRepository`.
- Finds the nearest five stops within 2 km of the pickup.
- Displays loading, empty, stale, error and retry states.
- A passenger can open a stop, inspect distance, source and update time, then
  select it as a Shared Economy connection.
- The selected stop appears on pickup confirmation and is saved as
  `transit_stop_id` and `transit_stop_name` on the ride.
- The same stop contributes the documented +10 carpool match bonus.

### Explainable carpool intelligence

- Pure Dart `CarpoolMatcher`, independent of widgets and Supabase.
- Filters same rider, non-shared ride, wrong status, over 15-minute departure
  difference, over four combined passengers, over 3 km pickup separation and
  over 45-degree direction difference.
- Tests every valid two-rider pickup-before-drop-off order using OSRM
  multi-waypoint routing.
- Rejects either rider above 25% detour and rejects scores below 60.
- Deterministic candidate ranking and human-readable match reasons.
- Atomic `create_carpool_match` RPC rechecks ownership, status, capacity,
  departure gap and concurrency.
- Shared map shows both pickups, both destinations and the optimised road route.
- Match sheet shows score, both detours, explanations and exact
  `vehicle-km avoided = solo A + solo B - merged route`.
- Vehicle-km avoided is persisted on `ride_groups` for Tey's analytics.
- No-match choices support keep waiting, cancel or atomically convert to solo
  Economy with the payment repriced to the solo amount.
- Shared cancellation retires the old group and releases an unmatched partner
  back to matching instead of leaving a ghost group.

### Contact Driver, completion and rating handoff

- Contact Driver is hidden until a real `driver_id` is assigned.
- Each booking has a private `ride_id` conversation; shared riders cannot read
  each other's chat.
- Chat is writable only during `driver_assigned` and `en_route`, and becomes
  read-only at completion/cancellation.
- Driver quick messages cover arrival, delay and pickup clarification.
- Completion opens one receipt only, even if Supabase emits the completed row
  repeatedly.
- The completed receipt exposes Tey's one-rating-per-ride driver rating flow.

## Cross-Team Integration Still Required

These are not missing Kueh algorithms. They are required inputs owned by other
members before the real multi-account demo can pass.

### Heng Jing Le

- Publish approved online drivers through `upsert_my_driver_presence` every
  location interval.
- Implement driver verification/vehicle-capacity gates before Online/Accept.
- List matched `ride_groups` as one driver order and call
  `accept_carpool_group` instead of accepting one member ride directly.
- Apply start/complete status to the group and both member rides atomically.
- Publish `assigned_driver_location` only for the assigned rides.

### Foo Tun Wei

- Review and apply the fare/payment migration containing
  `create_ride_with_quote_and_payment`, `continue_shared_ride_solo` and
  `cancel_ride_and_settle_payment`.
- Confirm wallet authorisation for every member payment when a shared group is
  accepted.
- Confirm final capture/cash settlement for every completed member ride.

### Tey Ying Heng

- Import official data.gov.my GTFS stops into `transit_stops` and keep
  `updated_at`/source metadata current.
- Use persisted `vehicle_km_avoided` and shared-group completion data in the
  Analytics Dashboard.
- Apply and verify the driver-rating migration and aggregate view.

## Required Manual Three-Account Demo

Use two passenger accounts and one approved driver account after migrations and
seed/import data are ready.

1. Passenger A chooses Shared Economy, one passenger and a transit connection.
2. Passenger B requests a compatible Shared Economy trip within 15 minutes.
3. Verify a score of at least 60, explanations, detours, stop order and
   vehicle-km avoided.
4. Accept the match and verify both rides share one `group_id`.
5. Driver accepts the group; verify both rides receive the same driver and both
   passengers see the registered vehicle.
6. Verify each passenger can contact the driver but cannot see the other
   passenger's messages.
7. Driver starts and completes the group; verify both payments/receipts.
8. Passenger submits one rating; verify a duplicate rating is rejected.
9. Repeat once with Passenger A cancelling before driver assignment; Passenger
   B must return to `waiting_match` and the previous group must be cancelled.

## Database Application Order

Review on a non-production Supabase project, then apply migrations in filename
order. Never test with real licences, selfies, phone numbers or payment data.

1. `20260828000000_k_trip_planner.sql`
2. `20260829000000_f_payments_wallet.sql`
3. `20260830000000_f_pickup_landmark_storage.sql`
4. `20260831000000_t_rewards.sql`
5. `20260901000000_t_driver_ratings.sql`

The current repository does not contain Heng's driver verification and vehicle
migration yet. Do not call the full MVP complete until that migration, driver
UI and the manual three-account demo have been added and verified.
