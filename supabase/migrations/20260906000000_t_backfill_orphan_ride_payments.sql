-- InfraGo Tey module: one-off data backfill.
--
-- The app's only ride-creation path (create_ride_with_quote_and_payment in
-- 20260829000000_f_payments_wallet.sql) always inserts a `payments` row
-- atomically alongside the `rides` row, so a ride cannot reach 'completed'
-- through normal app usage without ever having a payment. A completed ride
-- with zero payment rows was inserted directly (e.g. via the Studio table
-- editor) to test driver/admin/rating flows in isolation, bypassing that
-- RPC. This is not a code bug - it only backfills a plausible 'paid' cash
-- payment for any such orphaned completed ride, so downstream reporting
-- (this module's SDG/payment analytics) reflects a complete, consistent
-- record instead of a silent gap.
--
-- Scope is narrow and safe to re-run: only rides with status = 'completed'
-- AND zero existing payments rows are touched. idempotency_key is
-- deterministic per ride and unique-constrained, so re-running this file
-- is a no-op the second time (ON CONFLICT DO NOTHING).

INSERT INTO payments (
  ride_id, group_id, payer_id, method, status, idempotency_key,
  quoted_amount, discount_amount, reward_points_redeemed,
  cancellation_fee, refunded_amount, driver_compensation_amount,
  final_amount, currency, created_at, updated_at
)
SELECT
  r.id,
  r.group_id,
  r.rider_id,
  'cash',
  'paid',
  'backfill-orphan-payment-' || r.id::text,
  amt.v_amount,
  0,
  0,
  0,
  0,
  0,
  amt.v_amount,
  'MYR',
  COALESCE(r.completed_at, r.departure_time, now()),
  COALESCE(r.completed_at, r.departure_time, now())
FROM rides r
CROSS JOIN LATERAL (
  SELECT COALESCE(
    (
      SELECT CASE
        WHEN fq.service_type = 'shared_economy' AND r.group_id IS NOT NULL
          THEN COALESCE(fq.shared_amount, fq.solo_amount)
        ELSE fq.solo_amount
      END
      FROM fare_quotes fq
      WHERE fq.ride_id = r.id
      ORDER BY fq.quoted_at DESC
      LIMIT 1
    ),
    r.estimated_shared_fare,
    r.estimated_solo_fare,
    0
  ) AS v_amount
) amt
WHERE r.status = 'completed'
  AND NOT EXISTS (SELECT 1 FROM payments p WHERE p.ride_id = r.id)
ON CONFLICT (idempotency_key) DO NOTHING;
