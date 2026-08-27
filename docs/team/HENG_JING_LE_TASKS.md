# Heng Jing Le — Driver Onboarding, Operations and Live Ride

## Mission

Own the full driver journey: submit identity/vehicle information, become
eligible, go online, publish availability/location, safely accept and complete
solo/shared orders.

Read [the shared contract](README.md) before implementation.

## H1 — Identity and Vehicle Onboarding

Collect:

- Driver display name/contact.
- Driving licence image and current selfie.
- Manual-review consent.
- Vehicle make, model, colour, body type (`sedan`, `hatchback`, `mpv`, `suv`).
- Plate number and passenger capacity 1-6, excluding driver.
- One vehicle per driver for MVP.

Rules:

- Private Supabase bucket; only owner/admin signed URL access.
- File type/size validation, progress, retry, rejection and resubmission.
- Plate uppercase, remove spaces/hyphens, letters/digits only, length 3-12,
  unique in database.
- 6-Seater requires approved capacity at least six; SUV label alone is not
  enough.
- Approved six-seat driver may opt into Economy/Shared jobs.
- Honest wording: manual review/registered information, not face recognition,
  eKYC, OCR or verified ownership.

## H2 — Readiness and Online State

- Identity approved plus vehicle approved is required to go online.
- Missing/pending/rejected states show guidance/reason/resubmit action.
- Backend RPC/policy also blocks unapproved drivers.
- Persist availability safely and stop presence on offline/logout.

## H3 — Nearby Presence and Exact Location

While approved, online and unassigned:

- Publish coarse/anonymised presence and eligible service types.
- Update after meaningful movement/about 10-15 seconds.
- Stop when offline, assigned, app disposed or permission unavailable.

After assignment:

- Publish exact foreground location for trip participants only.
- Calculate/provide ETA to next ordered stop.
- Handle denied permission, GPS disabled, offline and stale states.
- Never implement background tracking in MVP.

Kueh consumes coarse presence before assignment and exact location after it.

## H4 — Available Orders

Show solo/shared cards with:

- Requested service, departure, passengers and payment method/status allowed.
- Pickup/destination or optimised group stop order.
- Distance, ETA, transit badge and capacity eligibility.
- Disable/filter jobs incompatible with vehicle service/capacity.

## H5 — Atomic Accept/Reject

- Accept through conditional RPC, not unconditional client update.
- Atomically recheck order status, driver/vehicle approval and capacity.
- Exactly one winner when two drivers accept simultaneously.
- Store `accepted_at` and `free_cancel_until` for Foo's cancellation policy.
- Prevent repeated taps/side effects.
- Driver dismiss does not cancel a public rider request.
- Trigger Demo Wallet authorisation through Foo's payment contract.

## H6 — Ride Lifecycle

```text
matched -> driver_assigned -> en_route -> completed
                              -> cancelled
```

- Guide driver through pickup, onboard, ordered stops and all drop-offs.
- Reject invalid status transitions.
- Publish every valid update through realtime.
- Completion/cancellation triggers Foo payment exactly once.
- Stop location/chat writes at terminal states.
- Driver cancellation requires reason and never charges rider.

## H7 — Assigned Rider Contact

- One private inbox entry per accepted `ride_id`.
- Shared group riders remain separate and cannot identify/chat each other.
- Quick messages: arrived, traffic delay, confirm pickup landmark.
- Writable only in `driver_assigned`/`en_route`; terminal state read-only.
- RLS blocks unassigned/unrelated conversations.
- Show active registered vehicle summary.

## H8 — Driver Satisfaction Summary

- Display Tey's average rating/count and anonymised tags/comments.
- New driver shows `No ratings yet`, not zero stars.
- Driver cannot edit/delete ratings or identify rider.

## Database Ownership

Heng owns:

- `driver_verifications`, `driver_vehicles`.
- Private licence/selfie owner storage policies.
- `driver_presence`/exact participant location and RLS.
- Availability, atomic acceptance, capacity and lifecycle RPCs.

Tey adds admin policies/UI; Kueh owns groups; Foo owns payments.

## Required Tests

- Identity/vehicle validation, upload, rejection/resubmission tests.
- Readiness UI and backend gate tests.
- Presence freshness/anonymisation/online-assigned transition tests.
- GPS throttle, stale, permission and disposal tests.
- Category/capacity filtering tests.
- Two-driver concurrent acceptance integration test.
- Valid/invalid lifecycle and payment-event tests.
- Per-ride chat RLS tests.
- Rating summary/empty/anonymised feedback tests.

## Acceptance Demo

1. Submit licence/selfie/vehicle and show pending/rejected states.
2. Tey approves; driver can go online.
3. Kueh sees fresh anonymised nearby car.
4. Show compatible solo/shared orders.
5. Demonstrate exactly one winner for concurrent acceptance.
6. Kueh switches to exact driver/ETA after assignment.
7. Driver contacts riders separately and completes ordered stops.
8. Payment settles and rating appears anonymously.

## Dependencies

- Kueh: matched group, stop order and rider map/chat consumer.
- Foo: payment authorise/complete/refund contract.
- Tey: approval decisions and rating aggregates.

## Work Order

1. Add onboarding migrations/storage/forms/tests.
2. Build readiness and online state.
3. Add coarse/exact location publication.
4. Upgrade solo/shared order cards.
5. Add atomic acceptance/capacity.
6. Add lifecycle, ETA and driver inbox.
7. Integrate payment and rating summary.

## Out of Scope

- Background tracking and turn-by-turn navigation.
- Automatic dispatch.
- Real driver payout/withdrawal.
- Vehicle photos, OCR, face recognition or eKYC.
- Live GTFS public-vehicle positions.

