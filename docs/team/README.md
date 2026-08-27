# InfraGo Team Development Guide

> This document is the shared contract. Features remain planned until their
> acceptance criteria and tests pass.

## Product

InfraGo is a Flutter first/last-mile ride platform for Malaysia. It combines
government GTFS/open data, route planning, explainable carpool matching,
verified driver onboarding, prototype payments, ratings, rewards and SDG 9
analytics.

## Ownership

| Member | Module | Task document |
|---|---|---|
| Kueh Jian Wei | Trip Planner, Map, Carpool Intelligence, rider Contact Driver | [Kueh Tasks](KUEH_JIAN_WEI_TASKS.md) |
| Foo Tun Wei | Passenger Booking, Pricing, Payment, Receipt | [Foo Tasks](FOO_TUN_WEI_TASKS.md) |
| Heng Jing Le | Driver Onboarding, Driver Hub, Orders, Live Ride | [Heng Tasks](HENG_JING_LE_TASKS.md) |
| Tey Ying Heng | GTFS/Open Data, Admin, Rewards, Ratings, Analytics | [Tey Tasks](TEY_YING_HENG_TASKS.md) |

## Commuter Flow

```text
locate and confirm pickup
-> search destination
-> route preview
-> select Economy 4 / 6-Seater / Shared Economy
-> choose Now or Schedule
-> confirm pickup, fare and payment
-> search rider match/driver
-> track assigned driver and Contact Driver
-> complete and pay
-> receipt, rewards and driver rating
```

Map states:

```text
explore -> route_preview -> vehicle_options -> pickup_confirmation
-> searching_driver -> driver_assigned -> en_route
-> completed | cancelled
```

## Service Rules

- `economy_4`: 1-4 passengers.
- `six_seater`: 1-6 passengers; approved capacity must be at least six.
- `shared_economy`: 1-2 seats per booking; at most two bookings/four riders.
- Schedule range: 15 minutes to 7 days ahead.
- Shared candidate time difference: at most 15 minutes.
- Pickup distance: at most 3 km.
- Direction difference: at most 45 degrees.
- Maximum rider detour: 25%.
- Match score must be at least 60.

## Pricing `mvp_v1`

```text
raw fare = RM3 + RM1.10/km + RM0.20/minute
economy = max(RM5, raw fare)
6-seater = economy x 1.35
matched shared = economy x 0.75
```

- Prices are coursework estimates, not commercial rates.
- Shared discount applies only after a valid match.
- An unmatched shared rider explicitly chooses continue as solo or cancel.
- Cash and Coursework Demo Wallet are the only MVP payment methods.
- No real card/bank data or actual money is collected.

## Cancellation `cancel_v1`

- Before driver assignment: free.
- First 3 minutes after driver acceptance: free.
- After grace and before `en_route`: 20% of confirmed fare, minimum RM2,
  maximum RM5.
- Scheduled ride stays free until 15 minutes before pickup and still requires
  an assigned driver plus expired grace period.
- Driver/system cancellation: free.
- Driver more than 5 minutes later than pickup ETA: free.
- Show exact fee before final confirmation.
- Demo Wallet applies fee/refund atomically. Cash records prototype amount due.

## Nearby Vehicle Privacy

- Pre-booking cars come from approved, online, unassigned drivers.
- Show only anonymised coarse coordinates and service type.
- Hide presence older than 60 seconds.
- Do not show ID, plate or exact coordinate before assignment.
- After assignment, only trip participants read exact foreground location.
- Label seeded cars as demo availability; never fake random cars as live.

## Contact Driver

- Hidden before `driver_id` exists.
- Writable only in `driver_assigned` and `en_route`.
- Every booking uses a private `ride_id` conversation.
- Shared riders cannot message or identify one another.
- Completed/cancelled chat is read-only.
- Only assigned rider/driver have RLS access.

## Rating

- Only completed ride's rider rates the assigned driver.
- One rating per ride, 1-5 stars, tags and optional 300-character comment.
- Driver sees aggregates/anonymised feedback, not rider identity.
- Admin moderates individual records.

## Shared Data Contract

```text
rides:
id, rider_id, driver_id, group_id, status,
pickup, pickup_latitude, pickup_longitude, pickup_note,
pickup_landmark_path,
destination, destination_latitude, destination_longitude,
route_distance_meters, route_duration_seconds,
ride_type, service_type, passenger_count, departure_time,
transit_stop_id, transit_stop_name,
estimated_solo_fare, estimated_shared_fare,
accepted_at, free_cancel_until, cancelled_at, cancelled_by,
cancellation_reason, cancellation_policy_version, cancellation_fee

ride_groups:
id, driver_id, status, total_passengers, match_score,
maximum_detour_ratio, route_distance_meters, route_duration_seconds,
vehicle_km_avoided, estimated_total_savings, stop_order

driver_verifications:
driver_id, licence_path, selfie_path, status, rejection_reason,
reviewed_by, reviewed_at

driver_vehicles:
driver_id, make, model, color, body_type, plate_number,
passenger_capacity, service_eligibility, approval_status, rejection_reason

driver_presence:
driver_id, availability, service_types,
coarse_latitude, coarse_longitude,
exact_latitude, exact_longitude, heading, updated_at

fare_quotes:
id, ride_id, pricing_version, service_type,
distance_meters, duration_seconds, base_amount,
vehicle_multiplier, solo_amount, shared_amount, currency, quoted_at

payments:
id, ride_id, group_id, payer_id, method, status,
quoted_amount, discount_amount, cancellation_fee,
refunded_amount, driver_compensation_amount, final_amount

driver_ratings:
id, ride_id, rider_id, driver_id, score, tags, comment,
issue_category, created_at, updated_at
```

Statuses:

```text
verification: pending | approved | rejected
ride: requested | waiting_match | matched | driver_assigned |
      en_route | completed | cancelled
group: searching | matched | driver_assigned | en_route |
       completed | cancelled
payment: pending | authorised | paid | failed | refunded | cancelled
```

## Integration Rules

- All branches start from the same baseline commit.
- Members edit their owned files and create separate timestamped migrations.
- Nobody applies unreviewed migrations to the shared Supabase project.
- Shared model/status/schema changes require team agreement.
- Team lead reviews PRs into `integration/mvp`; nobody merges directly to main.
- Every handoff includes branch/commit, files, migrations, tests, known issues,
  AI prompts and manual verification.

## Definition of Done

- Real flow works; no hard-coded success pretending to be live.
- Loading, empty, error, retry and validation states exist.
- RLS protects documents, chat, locations, payments and ratings.
- Unit/widget/integration tests cover boundaries.
- `flutter analyze`, `flutter test` and `flutter build apk --debug` pass.
- AI use is disclosed and the owner can explain the code.
- README claims only implemented/tested features.

