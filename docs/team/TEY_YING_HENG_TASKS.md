# Tey Ying Heng — Open Data, Admin, Rewards, Ratings and Analytics

## Mission

Own reusable Malaysian government/open-data services, administrator review,
profile/rewards, driver satisfaction and evidence that InfraGo supports SDG 9.

Read [the shared contract](README.md) before implementation.

## Current Starting Point

The repository has Provider-based OpenDOSM/World Bank clients, charts, caching,
error states and tests. Preserve working real-data behaviour while adding the
targets below.

## T1 — Official Open Data Dashboard

- Keep official external data separate from InfraGo-calculated metrics.
- Show source, timestamp and fresh/stale state.
- Support loading, empty, partial success, error, retry and cache fallback.
- Never label cache as live or prototype estimates as government statistics.

## T2 — GTFS TransitStopRepository

- Download official Malaysia data.gov.my GTFS Static.
- Parse/validate stops and ignore malformed/duplicate rows.
- Cache last successful dataset and source/update metadata locally.
- Expose loading, fresh, stale, empty, error and retry states.
- Supply stops to Kueh; Kueh owns nearest calculation and map presentation.
- Do not duplicate map UI or route planner.

## T3 — Admin Identity Review

- Admin-only pending queue.
- Show submitted driver/contact and short-lived signed licence/selfie URLs.
- Approve or reject with required reason.
- Ordinary users/drivers cannot access queue.
- Reviewer cannot review self.
- Never store/log signed URLs or expose documents to riders.
- Wording remains manual review, not face recognition/eKYC.

## T4 — Admin Vehicle Review

- Review make/model/colour/body type/plate/capacity/service eligibility.
- Approve/reject with reason.
- Explain that approval checks submitted information, not government ownership.
- A 6-Seater approval requires registered capacity at least six.

## T5 — Rewards

- Award points only after completed and paid ride.
- Immutable reward ledger; no balance-only updates.
- Prevent duplicate completion rewards.
- Prototype redemption: 100 points = RM1, at most 20% of fare.
- Provide atomic reserve/release contract to Foo.
- Restore reserved points after refund.

## T6 — Driver Rating and Satisfaction

- Completed ride's rider can rate assigned driver once.
- 1-5 stars, optional tags, optional comment up to 300 characters.
- Optional issue category for 1-2 stars.
- Database uniqueness on `ride_id`.
- Prevent self-rating and driver modification/deletion.
- Rider/public sees aggregate average/count only.
- Driver sees anonymised feedback.
- Admin moderates individual records.

Analytics:

- Average and count; 1-5 distribution.
- Frequent positive tags and low-rating rate.
- Exclude cancelled rides.
- Unrated driver is `No ratings yet`, not 0 stars.

## T7 — SDG and Operational Analytics

Show clearly separated `Official Government Data` and `InfraGo Prototype
Metrics`:

- Completed shared groups and transit-linked rides.
- Average passengers/vehicle and rider detour.
- Estimated savings and vehicle-km avoided.
- Vehicle capacity and service category distribution.
- Cancellation rate, free/fee split, reasons and prototype compensation.
- Payment method/status aggregates without private transaction detail.

Handle zero denominators, negative/bad imported values and date ranges.

## T8 — Profile and Coursework Evidence

- Show role, driver onboarding status, reward balance and rating summary.
- Keep profile consistent with Supabase auth.
- Maintain AI disclosure: tools, prompts, use, manual verification, limitations.
- Record contribution/test/demo evidence for Appendix D and presentation.

## Database Ownership

Tey owns:

- Admin role/authorisation and review update policies.
- GTFS local cache/repository.
- Reward accounts/immutable ledger and atomic rules.
- `driver_ratings`, rating RLS/aggregate/moderation.
- Analytics queries/views and dashboard state.

Heng owns base driver/vehicle tables; Tey adds admin policies separately. Foo
owns payment/wallet tables. Kueh owns groups/routes.

## Required Tests

- Open-data clients, partial failure and cache freshness tests.
- GTFS parse/duplicate/malformed/cache fallback tests.
- Admin/non-admin/self-review/signed URL tests.
- Vehicle category/capacity approval tests.
- Reward earn/reserve/release/refund/idempotency tests.
- Completed-only, one-per-ride, self-rating, RLS and anonymisation tests.
- Rating and SDG aggregate/zero/cancelled/negative-data tests.

## Acceptance Demo

1. Load official data and demonstrate offline cache/stale label.
2. Kueh receives official GTFS stops from repository.
3. Admin reviews Heng's licence/selfie and vehicle.
4. Completed paid ride awards points once.
5. Foo opens one-time driver rating.
6. Heng sees anonymous rating summary.
7. Dashboard separates official data from InfraGo SDG/payment/cancellation
   metrics.

## Dependencies

- Heng: verification/vehicle submissions and completed status.
- Kueh: match, detour, transit and vehicle-km values.
- Foo: payment completion/refund and rating entry point.

## Work Order

1. Stabilise existing open-data module/tests.
2. Implement GTFS repository for Kueh.
3. Define admin role and review Heng policies.
4. Build identity/vehicle queues.
5. Add rewards and rating data/RLS.
6. Add SDG/payment/cancellation/satisfaction analytics.
7. Run review-to-payment-to-rating/reward demo.

## Out of Scope

- Automated licence/face/vehicle verification.
- Claiming prototype metrics are official.
- Production-scale moderation or predictive ML.
- Real payout/refund processing.

