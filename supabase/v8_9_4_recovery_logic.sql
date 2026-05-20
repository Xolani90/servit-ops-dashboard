-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8.9.4 — Recovery Logic Improvements
-- 
-- STEP 1: Add recovery mechanisms for failed booking-to-matching flows
-- Ensure no booking stays stuck in SEARCHING or OFFERED permanently
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Expire stuck SEARCHING bookings after 5 minutes ───────────
-- PERFORMANCE FIX: Replaced FOR LOOP row-by-row updates with set-based UPDATE
-- to prevent lock contention under load. All operations are now batched.
DROP FUNCTION IF EXISTS expire_stuck_searching_bookings();
CREATE OR REPLACE FUNCTION expire_stuck_searching_bookings()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired_count INTEGER;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  -- Set-based UPDATE: expire all stuck SEARCHING bookings at once
  WITH stuck_bookings AS (
    SELECT id, customer_id
    FROM bookings
    WHERE status = 'SEARCHING'
      AND payment_status = 'paid'
      AND updated_at < now() - interval '5 minutes'
      AND (
        booking_mode = 'asap'
        OR (booking_mode = 'scheduled' AND scheduled_for <= now() + interval '2 hours')
      )
    FOR UPDATE
  )
  UPDATE bookings b
  SET 
    status = 'EXPIRED',
    cancelled_reason = 'No fixer available after 5 minutes',
    updated_at = now(),
    version = version + 1
  FROM stuck_bookings sb
  WHERE b.id = sb.id;

  GET DIAGNOSTICS v_expired_count = ROW_COUNT;

  -- Set-based UPDATE: refund all payments for expired bookings
  UPDATE payments
  SET 
    status = 'refunded',
    updated_at = now()
  WHERE booking_id IN (
    SELECT id FROM bookings
    WHERE status = 'EXPIRED'
      AND cancelled_reason = 'No fixer available after 5 minutes'
      AND payment_status = 'paid'
  )
  AND status = 'paid';

  -- Set-based INSERT: log audit events for all expired bookings
  INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata, created_by)
  SELECT 
    id,
    'searching_expired',
    'SEARCHING',
    'EXPIRED',
    jsonb_build_object(
      'reason', 'No fixer available after 5 minutes',
      'auto_refund', true
    ),
    customer_id
  FROM bookings
  WHERE status = 'EXPIRED'
    AND cancelled_reason = 'No fixer available after 5 minutes'
    AND updated_at = now();

  -- Set-based INSERT: notify all customers
  INSERT INTO notifications (user_id, title, body, type, related_id)
  SELECT 
    customer_id,
    '😔 No fixer available',
    'We couldn''t find a fixer for your job. Your payment has been refunded automatically.',
    'booking_expired',
    id
  FROM bookings
  WHERE status = 'EXPIRED'
    AND cancelled_reason = 'No fixer available after 5 minutes'
    AND updated_at = now();

  RETURN jsonb_build_object(
    'success', true,
    'expired_count', v_expired_count
  );
END;
$$;

-- ── 2. Expire stuck OFFERED bookings after 2 minutes ─────────────
-- PERFORMANCE FIX: Replaced FOR LOOP row-by-row updates with set-based UPDATE
-- to prevent lock contention under load. All operations are now batched.
DROP FUNCTION IF EXISTS expire_stuck_offered_bookings();
CREATE OR REPLACE FUNCTION expire_stuck_offered_bookings()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired_count INTEGER;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  -- Set-based UPDATE: return all stuck OFFERED bookings to SEARCHING
  WITH stuck_bookings AS (
    SELECT id, customer_id
    FROM bookings
    WHERE status = 'OFFERED'
      AND payment_status = 'paid'
      AND updated_at < now() - interval '2 minutes'
      AND offer_expires_at < now()
      AND NOT EXISTS (
        SELECT 1 FROM offers
        WHERE booking_id = bookings.id
          AND status = 'pending'
      )
    FOR UPDATE
  )
  UPDATE bookings b
  SET 
    status = 'SEARCHING',
    current_offer_id = NULL,
    offer_expires_at = NULL,
    updated_at = now(),
    version = version + 1
  FROM stuck_bookings sb
  WHERE b.id = sb.id;

  GET DIAGNOSTICS v_expired_count = ROW_COUNT;

  -- Set-based INSERT: log audit events for all retried bookings
  INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata, created_by)
  SELECT 
    b.id,
    'offered_retry',
    'OFFERED',
    'SEARCHING',
    jsonb_build_object(
      'reason', 'All offers expired, returning to search',
      'retry_count', COALESCE(be.retry_count, 0)
    ),
    b.customer_id
  FROM bookings b
  LEFT JOIN (
    SELECT booking_id, COUNT(*) as retry_count
    FROM booking_events
    WHERE event_type = 'offered_retry'
    GROUP BY booking_id
  ) be ON be.booking_id = b.id
  WHERE b.status = 'SEARCHING'
    AND b.updated_at = now();

  RETURN jsonb_build_object(
    'success', true,
    'retry_count', v_expired_count
  );
END;
$$;

-- ── 3. Enhanced match_fixers with recovery logging ───────────────
DROP FUNCTION IF EXISTS match_fixers(UUID, DOUBLE PRECISION, INTEGER);
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
  v_match_attempt_count INTEGER;
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

  -- Count previous match attempts for recovery tracking
  SELECT COUNT(*) INTO v_match_attempt_count
  FROM booking_events
  WHERE booking_id = p_booking_id
    AND event_type IN ('match_attempt', 'manual_retry_search');

  -- Log match attempt
  INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata)
  VALUES (
    v_booking.id,
    'match_attempt',
    'SEARCHING',
    'SEARCHING',
    jsonb_build_object(
      'attempt_number', v_match_attempt_count + 1,
      'radius_km', p_radius_km,
      'batch_size', p_batch_size
    )
  );

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
      AND f.last_seen_at >= now() - interval '8 minutes'
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
      AND (
        v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (
          SELECT 1 FROM fixer_categories fc
          WHERE fc.fixer_id = f.id AND fc.category = v_booking.category
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM offers o
        WHERE  o.booking_id = v_booking.id
          AND  o.fixer_id   = f.id
          AND  o.status     IN ('declined', 'expired')
      )
    ORDER BY
      CASE WHEN f.acceptance_rate < 60 THEN 1 ELSE 0 END ASC,
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
          'batch_position', v_offers_sent,
          'attempt_number', v_match_attempt_count + 1
        )
      );
    END IF;
  END LOOP;

  IF v_offers_sent = 0 THEN
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
      'booking_id', v_booking.id,
      'attempt_number', v_match_attempt_count + 1
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
    'expires_at',   v_offer_expires_at,
    'attempt_number', v_match_attempt_count + 1
  );
END;
$$;

-- ── 4. Update expire_offers to handle stuck OFFERED state ─────────
DROP FUNCTION IF EXISTS expire_offers();
CREATE OR REPLACE FUNCTION expire_offers()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired_count INTEGER := 0;
  v_offer RECORD;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  -- Expire individual offers
  FOR v_offer IN
    SELECT o.id, o.booking_id, o.fixer_id, f.user_id AS fixer_user_id
    FROM offers o
    JOIN fixers f ON f.id = o.fixer_id
    WHERE o.status = 'pending'
      AND o.expires_at < now()
    FOR UPDATE OF o
  LOOP
    UPDATE offers
    SET status = 'expired',
        responded_at = now()
    WHERE id = v_offer.id;

    INSERT INTO notifications (user_id, title, body, type, related_id)
    VALUES (
      v_offer.fixer_user_id,
      '⏰ Offer expired',
      'The job offer has expired. Stay available for the next one!',
      'offer_expired',
      v_offer.booking_id
    );

    v_expired_count := v_expired_count + 1;
  END LOOP;

  -- After expiring offers, check if any bookings are now stuck in OFFERED
  PERFORM expire_stuck_offered_bookings();

  RETURN jsonb_build_object(
    'success', true,
    'expired_count', v_expired_count
  );
END;
$$;

-- ── 5. Add recovery cron jobs ─────────────────────────────────────
SELECT cron.schedule(
  'expire-stuck-searching',
  '* * * * *',
  $$ SELECT expire_stuck_searching_bookings(); $$
);

SELECT cron.schedule(
  'expire-stuck-offered',
  '* * * * *',
  $$ SELECT expire_stuck_offered_bookings(); $$
);

-- ── 6. Migration tracking ─────────────────────────────────────────
INSERT INTO schema_migrations (version) VALUES ('v8.9.4') ON CONFLICT DO NOTHING;
