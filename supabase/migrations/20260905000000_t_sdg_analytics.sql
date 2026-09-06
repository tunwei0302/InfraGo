CREATE OR REPLACE FUNCTION sdg_operational_analytics(
  p_start TIMESTAMPTZ DEFAULT NULL,
  p_end TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start TIMESTAMPTZ := COALESCE(p_start, '-infinity'::timestamptz);
  v_end TIMESTAMPTZ := COALESCE(p_end, 'infinity'::timestamptz);
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'authentication_required');
  END IF;
  IF p_start IS NOT NULL AND p_end IS NOT NULL AND p_start > p_end THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'invalid_date_range');
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'range', jsonb_build_object('start', p_start, 'end', p_end),

    'sdg', (
      SELECT jsonb_build_object(
        'completed_rides', COUNT(*) FILTER (WHERE r.status = 'completed'),
        'transit_linked_rides', COUNT(*) FILTER (
          WHERE r.status = 'completed' AND r.transit_stop_id IS NOT NULL
        )
      )
      FROM rides r
      WHERE r.completed_at BETWEEN v_start AND v_end
    ) || (
      SELECT jsonb_build_object(
        'shared_groups_completed', COUNT(*),
        'avg_passengers_per_vehicle', ROUND(AVG(GREATEST(g.total_passengers, 0))::numeric, 2),
        'vehicle_km_avoided', ROUND(COALESCE(SUM(GREATEST(COALESCE(g.vehicle_km_avoided, 0), 0)), 0)::numeric, 1)
      )
      FROM ride_groups g
      WHERE g.status = 'completed' AND g.completed_at BETWEEN v_start AND v_end
    ) || jsonb_build_object(
      'avg_rider_detour_ratio', (
        SELECT ROUND((AVG(GREATEST(m.detour_percent, 0)) / 100.0)::numeric, 4)
        FROM ride_group_members m
        JOIN ride_groups g ON g.id = m.group_id
        WHERE g.status = 'completed' AND g.completed_at BETWEEN v_start AND v_end
      ),

      'estimated_savings_myr', (
        SELECT ROUND(COALESCE(SUM(GREATEST(
          COALESCE(lq.solo_amount, 0) - COALESCE(p.final_amount, lq.shared_amount, lq.solo_amount, 0),
          0
        )), 0)::numeric, 2)
        FROM rides r
        JOIN LATERAL (
          SELECT fq.solo_amount, fq.shared_amount
          FROM fare_quotes fq
          WHERE fq.ride_id = r.id
          ORDER BY fq.quoted_at DESC
          LIMIT 1
        ) lq ON TRUE
        LEFT JOIN payments p ON p.ride_id = r.id AND p.status = 'paid'
        WHERE r.status = 'completed' AND r.group_id IS NOT NULL
          AND r.completed_at BETWEEN v_start AND v_end
      )
    ),

    'vehicle_capacity_distribution', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('capacity', v.passenger_capacity, 'count', v.n) ORDER BY v.passenger_capacity)
      FROM (
        SELECT passenger_capacity, COUNT(*) AS n
        FROM driver_vehicles
        WHERE approval_status = 'approved'
        GROUP BY passenger_capacity
      ) v
    ), '[]'::jsonb),

    'service_category_distribution', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('service_type', s.service_type, 'count', s.n) ORDER BY s.service_type)
      FROM (
        SELECT service_type, COUNT(*) AS n
        FROM rides
        WHERE status = 'completed' AND completed_at BETWEEN v_start AND v_end
        GROUP BY service_type
      ) s
    ), '[]'::jsonb),

    'cancellations', (
      SELECT jsonb_build_object(
        'cancelled_count', COUNT(*) FILTER (
          WHERE r.status = 'cancelled' AND r.cancelled_at BETWEEN v_start AND v_end
        ),
        'completed_count', (
          SELECT COUNT(*) FROM rides WHERE status = 'completed' AND completed_at BETWEEN v_start AND v_end
        ),
        'free_cancellation_count', COUNT(*) FILTER (
          WHERE r.status = 'cancelled' AND r.cancelled_at BETWEEN v_start AND v_end
            AND COALESCE(r.cancellation_fee, 0) <= 0
        ),
        'fee_cancellation_count', COUNT(*) FILTER (
          WHERE r.status = 'cancelled' AND r.cancelled_at BETWEEN v_start AND v_end
            AND COALESCE(r.cancellation_fee, 0) > 0
        )
      )
      FROM rides r
    ) || jsonb_build_object(
      'top_reasons', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('reason', t.reason, 'count', t.n))
        FROM (
          SELECT cancellation_reason AS reason, COUNT(*) AS n
          FROM rides
          WHERE status = 'cancelled' AND cancelled_at BETWEEN v_start AND v_end
            AND cancellation_reason IS NOT NULL AND trim(cancellation_reason) <> ''
          GROUP BY cancellation_reason
          ORDER BY COUNT(*) DESC
          LIMIT 5
        ) t
      ), '[]'::jsonb),
      'prototype_driver_compensation_myr', COALESCE((
        SELECT ROUND(SUM(GREATEST(driver_compensation_amount, 0))::numeric, 2)
        FROM payments
        WHERE created_at BETWEEN v_start AND v_end
          AND driver_compensation_amount > 0
      ), 0)
    ),

    'payments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'method', x.method, 'status', x.status, 'count', x.n, 'total_myr', x.total
      ) ORDER BY x.method, x.status)
      FROM (
        SELECT method, status, COUNT(*) AS n,
          ROUND(SUM(GREATEST(COALESCE(final_amount, quoted_amount, 0), 0))::numeric, 2) AS total
        FROM payments
        WHERE created_at BETWEEN v_start AND v_end
        GROUP BY method, status
      ) x
    ), '[]'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION sdg_operational_analytics(TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sdg_operational_analytics(TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
