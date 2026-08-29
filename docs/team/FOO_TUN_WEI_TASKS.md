# Foo Tun Wei — Passenger Booking, Pricing and Payment

## Mission

Own the commuter transaction after Kueh produces a route: service selection,
booking validation, transparent fare, safe prototype payment, cancellation,
receipt and trip history.

Read [the shared contract](README.md) before implementation.

## F1 — Ride Options and Booking

After a valid route, show:

- Economy 4-Seater: 1-4 passengers.
- 6-Seater MPV/SUV: 1-6 passengers.
- Shared Economy: 1-2 seats, potential saving.
- Category capacity, pickup ETA supplied by Kueh/Heng and fare.
- Now or Schedule (15 minutes to 7 days ahead).
- Pickup/destination/route/transit summary.
- Optional pickup note.
- Shared no-match choice: continue solo or cancel.

Validate coordinates, category capacity, future schedule, required fields and
prevent duplicate submission. Preserve inputs on failure and allow retry.

## F2 — Pickup Landmark Image

- Optional capture/gallery selection with `image_picker`.
- Validate format, dimensions and size; compress large images where practical.
- Store privately; only rider and assigned driver can access.
- Denied camera permission must not block booking.
- Show upload progress/error/retry.

## F3 — FareEstimator `mvp_v1`

Pure Dart formula:

```text
raw = RM3 + RM1.10/km + RM0.20/minute
economy = max(RM5, raw)
6-seater = economy x 1.35
matched shared = economy x 0.75
```

- Use Kueh's OSRM distance/duration.
- Round only final money to two decimals.
- Shared amount is potential until matched.
- Save formula version, service, multiplier, route inputs, currency and time in
  `fare_quotes`.
- Never silently change an accepted quote.
- Label as coursework estimate.

## F4 — Checkout and Demo Payment

Methods:

- Cash: pending, then paid on completion.
- Coursework Demo Wallet: reserve on driver acceptance, capture on completion,
  release/refund on eligible cancellation.

Requirements:

- Never collect real card/bank credentials or actual money.
- Wallet operations use atomic Supabase RPC/database transactions.
- Every balance change has immutable ledger entry.
- Enforce idempotency/one current payment per ride.
- Handle insufficient balance and retry without duplicate charge.

## F5 — CancellationPolicy `cancel_v1`

- Before driver assignment: free.
- First 3 minutes after acceptance: free.
- After grace and before `en_route`: 20% of confirmed fare, min RM2, max RM5.
- Scheduled ride remains free until 15 minutes before pickup and still requires
  assigned driver plus expired grace.
- Driver/system cancellation: free.
- Driver over pickup ETA by more than 5 minutes: free.

Show the exact fee before final confirmation. Demo Wallet deducts only fee and
releases/refunds remainder atomically. Cash records prototype amount due.
Persist policy version, timestamps, reason, fee, refund and prototype driver
compensation exactly once.

## F6 — Receipt, History and Book Again

- Show route, category, fare breakdown, discount, payment/refund status/date.
- Completed receipt opens Tey's rating flow if unrated.
- Trip history supports receipt view.
- `Book again` reuses location labels/coordinates but requests fresh route and
  fare; never copy old price.

## F7 — Reward Redemption

- Consume Tey's reward balance.
- Prototype rate: 100 points = RM1.
- Maximum redemption: 20% of fare.
- Reserve/deduct atomically with payment.
- Restore points after refund/cancellation.

## Database Ownership

Foo owns:

- Passenger booking/payment fields.
- `fare_quotes`, `payments`.
- `wallet_accounts`, immutable `wallet_transactions`.
- Pickup-landmark private storage policies.
- Atomic wallet authorise/capture/refund RPCs.
- Idempotency constraints and cancellation payment fields.

Foo does not own driver onboarding, location, matching, GTFS, ratings or admin.

## Required Tests

- Form, category capacity, schedule and duplicate-submit widget tests.
- Landmark permission/file/upload tests.
- Fare minimum, category multiplier, shared discount and rounding tests.
- Cash/wallet/insufficient balance/idempotency tests.
- Cancellation time, scheduled cutoff, delay and fee-clamp boundaries.
- Refund and reward restoration tests.
- Receipt, history, Book Again and rating-entry visibility tests.

## Acceptance Demo

1. Select Economy, 6-Seater and Shared with valid capacity filtering.
2. Schedule a valid ride and reject invalid times.
3. Show explainable category prices.
4. Confirm Cash and Demo Wallet checkout.
5. Cancel free while searching.
6. Show countdown and exact post-grace fee after assignment.
7. Complete payment, receipt, rating handoff and Book Again.

## Dependencies

- Kueh: route, locations, transit selection, group match and map sheet host.
- Heng: acceptance/completion/cancellation and pickup ETA events.
- Tey: rewards and rating submission status.

## Work Order

1. Agree `RideRequest` with Kueh.
2. Implement/test fare and cancellation policies.
3. Add payment/wallet migrations and RLS.
4. Build ride options, booking and checkout.
5. Add landmark upload.
6. Add receipt/history/rewards/rating handoff.
7. Test booking-to-receipt and booking-to-refund end to end.

## Out of Scope

- Stripe, FPX, cards, real wallet top-up or real money.
- Commercially accurate/surge fares.
- Driver payout/withdrawal.
- Driver identity/vehicle onboarding.

