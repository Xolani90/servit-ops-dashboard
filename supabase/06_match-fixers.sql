-- ═══════════════════════════════════════════════════════════════
-- match_fixers — v5.2 (no changes from v5.1 version)
-- Category column now exists on bookings (added in schema.sql),
-- so the category filter works correctly. No function changes needed.
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION match_fixers(
  p_booking_id  UUID,
  p_radius_km   DOUBLE PRECISION DEFAULT 25.0,
  p_batch_size  INTEGER          DEFAULT 3
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking          bookings%ROWTYPE;
  v_fixer            RECORD;
  v_offer_id         UUID;
  v_offer_expires_at TIMESTAMPTZ;
  v_customer_lat     DOUBLE PRECISION;
  v_customer_lng     DOUBLE PRECISION;
  v_customer_city    TEXT;
  v_offers_sent      INTEGER := 0;
  v_first_offer_id   UUID;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Booking not found');
  END IF;

  IF v_booking.status != 'SEARCHING' OR v_booking.payment_status != 'paid' THEN
    RETURN jsonb_build_object('error', 'Booking not available for matching');
  END IF;

  -- Scheduled bookings: don't match until 2h before slot
  IF v_booking.booking_mode = 'scheduled'
     AND v_booking.scheduled_for > now() + interval '2 hours' THEN
    RETURN jsonb_build_object('error', 'Scheduled booking not ready for matching');
  END IF;

  v_customer_lat  := v_booking.customer_latitude;
  v_customer_lng  := v_booking.customer_longitude;

  SELECT p.city INTO v_customer_city
  FROM profiles p WHERE p.id = v_booking.customer_id;

  v_offer_expires_at := now() + interval '45 seconds';

  FOR v_fixer IN
    SELECT f.*
    FROM fixers f
    WHERE f.status    = 'approved'
      AND f.available = true
      AND f.last_seen_at >= now() - interval '8 minutes'  -- FIX D: v8.5 comment said 8 min but SQL was never updated from 3 min
      -- Location: use geo radius when both sides have coordinates.
      -- If coordinates are missing, fall back to city text matching.
      AND (
        (
          f.latitude IS NOT NULL
          AND f.longitude IS NOT NULL
          AND v_customer_lat IS NOT NULL
          AND v_customer_lng IS NOT NULL
          AND (
            2 * 6371 * asin(sqrt(
              power(sin(radians((f.latitude  - v_customer_lat)  / 2)), 2) +
              cos(radians(v_customer_lat)) *
              cos(radians(f.latitude)) *
              power(sin(radians((f.longitude - v_customer_lng) / 2)), 2)
            ))
          ) <= p_radius_km
        )
        OR
        (
          (v_customer_lat IS NULL OR v_customer_lng IS NULL OR f.latitude IS NULL OR f.longitude IS NULL)
          AND f.city = v_customer_city
        )
      )
      -- Category enforcement: now works correctly since bookings.category exists
      AND (
        v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (
          SELECT 1 FROM fixer_categories fc
          WHERE fc.fixer_id = f.id AND fc.category = v_booking.category
        )
      )
      -- Skip fixers already declined or expired on this booking
      AND NOT EXISTS (
        SELECT 1 FROM offers o
        WHERE  o.booking_id = v_booking.id
          AND  o.fixer_id   = f.id
          AND  o.status     IN ('declined', 'expired')
      )
    ORDER BY
      -- Deprioritise low acceptance rate
      CASE WHEN f.acceptance_rate < 60 THEN 1 ELSE 0 END ASC,
      -- Geo distance when available
      CASE
        WHEN f.latitude IS NOT NULL AND f.longitude IS NOT NULL
             AND v_customer_lat IS NOT NULL AND v_customer_lng IS NOT NULL
        THEN
          2 * 6371 * asin(sqrt(
            power(sin(radians((f.latitude  - v_customer_lat)  / 2)), 2) +
            cos(radians(v_customer_lat)) *
            cos(radians(f.latitude)) *
            power(sin(radians((f.longitude - v_customer_lng) / 2)), 2)
          ))
        ELSE 0
      END ASC,
      f.rating DESC,
      f.jobs_completed ASC
    LIMIT p_batch_size
  LOOP
    INSERT INTO offers (booking_id, fixer_id, expires_at)
    VALUES (v_booking.id, v_fixer.id, v_offer_expires_at)
    ON CONFLICT (booking_id, fixer_id) DO NOTHING
    RETURNING id INTO v_offer_id;

    IF v_offer_id IS NOT NULL THEN
      v_offers_sent := v_offers_sent + 1;

      IF v_first_offer_id IS NULL THEN
        v_first_offer_id := v_offer_id;
      END IF;

      INSERT INTO notifications (user_id, title, body, type, related_id)
      VALUES (
        v_fixer.user_id,
        '🔔 New job offer!',
        'A client needs help' ||
          COALESCE(' (' || v_booking.category || ')', '') ||
          '. Accept within 45 seconds.',
        'job_offer',
        v_offer_id
      );

      INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata)
      VALUES (
        v_booking.id, 'offer_created', 'SEARCHING', 'OFFERED',
        jsonb_build_object(
          'fixer_id',       v_fixer.id,
          'offer_id',       v_offer_id,
          'match_method',   CASE WHEN v_customer_lat IS NOT NULL THEN 'geo' ELSE 'city_text' END,
          'batch_position', v_offers_sent
        )
      );
    END IF;
  END LOOP;

  IF v_offers_sent = 0 THEN
    -- Broadcast demand alert to offline fixers in the area
    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT
      f.user_id,
      '💼 Job available near you!',
      'A client needs help' ||
        COALESCE(' (' || v_booking.category || ')', '') ||
        COALESCE(' in ' || v_customer_city, ' in your area') ||
        '. Go online to accept.',
      'demand_alert',
      v_booking.id
    FROM fixers f
    WHERE f.status = 'approved'
      AND f.city = v_customer_city
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE  n.user_id    = f.user_id
          AND  n.related_id = v_booking.id
          AND  n.type       = 'demand_alert'
      );

    PERFORM pg_notify(
      'demand_alert',
      jsonb_build_object('booking_id', v_booking.id, 'city', v_customer_city)::text
    );

    RETURN jsonb_build_object(
      'error',      'No fixers available',
      'broadcast',  true,
      'booking_id', v_booking.id
    );
  END IF;

  UPDATE bookings SET
    status           = 'OFFERED',
    offered_at       = now(),
    current_offer_id = v_first_offer_id,
    offer_expires_at = v_offer_expires_at,
    updated_at       = now(),
    version          = version + 1
  WHERE id = v_booking.id;

  RETURN jsonb_build_object(
    'success',      true,
    'booking_id',   v_booking.id,
    'status',       'OFFERED',
    'offers_sent',  v_offers_sent,
    'expires_at',   v_offer_expires_at
  );
END;
$$;
