# Kueh Jian Wei — Trip Planner, Map and Carpool Intelligence

## Mission

Own the commuter's map journey from location search to a matched/assigned ride.
This is the main map, routing and explainable algorithm module.

Read [the shared contract](README.md) before implementation.

## Current Starting Point

The repository has OSM, Photon search, GPS, pickup/destination selection, an
OSRM service, ride status and chat foundations. These must be inspected and
tested; they are not automatically considered complete.

## K1 — State-Driven Bolt-Style Map

Implement one controller/state model:

```text
explore -> route_preview -> vehicle_options -> pickup_confirmation
-> searching_driver -> driver_assigned -> en_route
-> completed | cancelled
```

- Locate rider and default pickup to current position.
- Allow manual search and draggable roadside pickup pin.
- Search destination with Photon and handle stale responses.
- Draw real OSRM geometry, distance and trip ETA.
- Fit pickup/destination in camera and keep map attribution visible.
- Host Foo's vehicle/price bottom sheet without owning pricing.
- Confirm pickup note/landmark summary and Confirm button.
- Show fee-free cancel while searching.
- After acceptance show exact assigned car, pickup ETA, driver/vehicle/rating,
  Contact Driver and cancellation countdown.
- Clear stale overlays/subscriptions on back, cancel and state changes.

## K2 — Nearby Vehicles

- Subscribe to anonymised/coarse online presence supplied by Heng.
- Show only approved, online, unassigned vehicles compatible with categories.
- Hide presence older than 60 seconds.
- Animate updates efficiently.
- Before assignment never expose driver ID, plate or exact location.
- Show `No nearby drivers` when empty.
- Label seeded data as demo availability.
- After assignment switch to exact participant-protected driver location.

## K3 — Transit Stop Map

- Consume Tey's `TransitStopRepository`; do not create another GTFS client.
- Calculate/display five nearest stops within 2 km.
- Allow an optional stop as pickup/destination connection.
- Show source and last-updated/stale metadata.
- Handle loading, no nearby stop, error and retry.

## K4 — Carpool Matcher

Create a pure Dart `CarpoolMatcher` outside widgets.

Candidate requirements:

- Different riders, both `shared_economy`, waiting for match.
- Departure difference at most 15 minutes.
- Combined passengers at most four.
- Pickup distance at most 3 km.
- Direction difference at most 45 degrees.
- Same rider's orders never match.

Route evaluation:

- Generate valid sequences where pickup precedes that rider's destination.
- Request OSRM multi-waypoint routes and select shortest valid sequence.
- Reject if either rider detour exceeds 25%.
- Never turn route/API failure into a fake successful match.

Score:

```text
100
- 40 x (maximum detour / 25%)
- 30 x (time difference / 15 minutes)
- 20 x (pickup distance / 3 km)
+ 10 for the same transit stop
```

- Clamp 0-100 and reject below 60.
- Deterministic tie-breaker.
- Return human-readable match explanations.
- Create/join groups through an atomic database RPC that rechecks capacity and
  status.

## K5 — Shared Route Experience

- Display two pickups, two destinations and optimised stop order.
- Distinguish each rider's markers clearly.
- Show match score, reasons, detour, saving and vehicle-km avoided.
- Keep the rider's own pickup/destination visible.
- Handle cancellation without leaving a fake active group.
- Preserve solo flow.

## K6 — Rider Contact Driver

- Hidden before assigned `driver_id` exists.
- One private conversation per `ride_id`, including shared bookings.
- Writable only in `driver_assigned` and `en_route`.
- Shared riders cannot see/message one another.
- Show assigned driver/vehicle above chat.
- Receive arrival, delay and pickup-clarification quick messages.
- Completed/cancelled conversations are read-only.
- RLS limits access to assigned rider and driver.

## Database Ownership

Kueh owns:

- Shared-ride/group fields and `ride_groups` migration.
- Group creation/join RPC.
- Multi-stop order/match result persistence.
- Ride-scoped message policy changes needed for Contact Driver.

Kueh does not own fares/payments, driver presence publication, GTFS download,
driver verification, ratings or admin.

## Required Tests

- Photon search/reverse/stale response tests.
- OSRM single/multi-stop/error/cache tests.
- Map-state back/cancel/subscription tests.
- Nearby freshness/anonymisation/empty tests.
- Nearest-stop tests using Tey's fake repository.
- Matcher boundaries: time, seats, distance, direction, detour, score and user.
- Deterministic candidate order and atomic group conflict tests.
- Contact visibility, lifecycle and RLS mapping tests.

## Acceptance Demo

1. Locate rider, adjust pickup and search destination.
2. Draw real route/distance/ETA.
3. Display fresh anonymous nearby cars.
4. Show Tey's nearby official transit stops.
5. Host Foo's category/price sheet and confirm pickup.
6. Match two compatible shared requests with explanation.
7. Track Heng's assigned driver and ETA.
8. Contact only the assigned driver.

## Dependencies

- Foo: `RideRequest`, fare quote, vehicle option sheet and cancellation result.
- Heng: presence, exact assigned location, status and driver chat.
- Tey: GTFS repository and rating aggregate.

## Work Order

1. Stabilise single route/search and tests.
2. Add explicit map state controller.
3. Integrate coarse/exact vehicle streams.
4. Add multi-stop routing and matcher.
5. Integrate Tey transit repository.
6. Add shared route and Contact Driver.
7. Run the two-rider/one-driver end-to-end demo.

## Out of Scope

- Fare/payment implementation.
- Driver location publication.
- GTFS download/parser/cache.
- Background navigation or tracking.
- More than two shared bookings.

