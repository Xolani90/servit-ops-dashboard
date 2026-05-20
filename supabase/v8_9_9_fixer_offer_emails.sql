-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8.9.9 — Fixer Job Offer Email Notifications
--
-- Adds backup email notifications to fixers when job offers are created.
-- After each offer is created and the push notification is sent,
-- a backup email is sent to the fixer using the sendEmail utility.
-- Subject: 'New job offer — respond in 45 seconds'
-- HTML body includes service category, customer area, and instruction
-- to open the Servit app immediately. Includes null check for fixer email.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Add last_match_triggered_at column to bookings table ───────
ALTER TABLE bookings 
ADD COLUMN IF NOT EXISTS last_match_triggered_at TIMESTAMPTZ;

-- Add index for efficient querying
CREATE INDEX IF NOT EXISTS idx_bookings_last_match_triggered_at 
ON bookings(last_match_triggered_at) 
WHERE last_match_triggered_at IS NOT NULL;

-- ── 2. Add metadata column to offers table ─────────────────────────
ALTER TABLE offers ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::jsonb;

-- ── 3. Modify match_fixers to set email_pending flag on offer creation ──
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
  v_log_id           UUID;
  v_start_time       TIMESTAMPTZ := now();
  v_cooldown_seconds INTEGER := 90;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  -- Log function start
  v_log_id := log_booking_transition(
    p_booking_id => p_booking_id,
    p_event_type => 'match_fixers_start',
    p_source => 'rpc',
    p_metadata => jsonb_build_object(
      'radius_km', p_radius_km,
      'batch_size', p_batch_size
    )
  );

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM log_booking_transition(
      p_booking_id => p_booking_id,
      p_event_type => 'match_fixers_error',
      p_source => 'rpc',
      p_error_message => 'Booking not found'
    );
    RETURN jsonb_build_object('error', 'Booking not found');
  END IF;

  -- COOLDOWN GUARD: Check if match was triggered recently
  IF v_booking.last_match_triggered_at IS NOT NULL 
     AND v_booking.last_match_triggered_at > now() - (v_cooldown_seconds || ' seconds')::interval
  THEN
    PERFORM log_booking_transition(
      p_booking_id => p_booking_id,
      p_event_type => 'match_fixers_cooldown',
      p_old_status => v_booking.status,
      p_source => 'rpc',
      p_error_message => 'Match triggered within cooldown period',
      p_metadata => jsonb_build_object(
        'last_triggered', v_booking.last_match_triggered_at,
        'cooldown_seconds', v_cooldown_seconds,
        'seconds_since_last_match', EXTRACT(EPOCH FROM (now() - v_booking.last_match_triggered_at))
      )
    );
    RETURN jsonb_build_object(
      'error', 'Match triggered within cooldown period',
      'last_triggered_at', v_booking.last_match_triggered_at,
      'cooldown_seconds', v_cooldown_seconds
    );
  END IF;

  IF v_booking.status != 'SEARCHING' OR v_booking.payment_status != 'paid' THEN
    PERFORM log_booking_transition(
      p_booking_id => p_booking_id,
      p_event_type => 'match_fixers_error',
      p_old_status => v_booking.status,
      p_payment_status => v_booking.payment_status,
      p_source => 'rpc',
      p_error_message => 'Booking not available for matching'
    );
    RETURN jsonb_build_object('error', 'Booking not available for matching');
  END IF;

  IF v_booking.booking_mode = 'scheduled'
     AND v_booking.scheduled_for > now() + interval '2 hours' THEN
    PERFORM log_booking_transition(
      p_booking_id => p_booking_id,
      p_event_type => 'match_fixers_error',
      p_source => 'rpc',
      p_error_message => 'Scheduled booking not ready for matching'
    );
    RETURN jsonb_build_object('error', 'Scheduled booking not ready for matching');
  END IF;

  -- UPDATE last_match_triggered_at to prevent concurrent calls
  UPDATE bookings
  SET last_match_triggered_at = now()
  WHERE id = p_booking_id;

  SELECT COUNT(*) INTO v_match_attempt_count
  FROM booking_events
  WHERE booking_id = p_booking_id
    AND event_type IN ('match_attempt', 'manual_retry_search');

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

  PERFORM log_booking_transition(
    p_booking_id => p_booking_id,
    p_event_type => 'match_attempt',
    p_old_status => v_booking.status,
    p_source => 'rpc',
    p_metadata => jsonb_build_object(
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
    INSERT INTO offers (booking_id, fixer_id, expires_at, metadata)
    VALUES (v_booking.id, v_fixer.id, v_offer_expires_at, jsonb_build_object('email_pending', true))
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

      PERFORM log_booking_transition(
        p_booking_id => v_booking.id,
        p_event_type => 'offer_created',
        p_old_status => 'SEARCHING',
        p_new_status => 'OFFERED',
        p_source => 'rpc',
        p_metadata => jsonb_build_object(
          'fixer_id', v_fixer.id,
          'offer_id', v_offer_id,
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

    PERFORM log_booking_transition(
      p_booking_id => v_booking.id,
      p_event_type => 'no_fixers_available',
      p_old_status => v_booking.status,
      p_source => 'rpc',
      p_metadata => jsonb_build_object(
        'attempt_number', v_match_attempt_count + 1,
        'broadcast', true
      )
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

  PERFORM log_booking_transition(
    p_booking_id => v_booking.id,
    p_event_type => 'match_fixers_success',
    p_old_status => 'SEARCHING',
    p_new_status => 'OFFERED',
    p_source => 'rpc',
    p_metadata => jsonb_build_object(
      'offers_sent', v_offers_sent,
      'attempt_number', v_match_attempt_count + 1,
      'duration_ms', EXTRACT(EPOCH FROM (now() - v_start_time)) * 1000
    )
  );

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

-- ── 4. Atomic claim function for pending offer emails ───────────────
CREATE OR REPLACE FUNCTION claim_pending_offer_emails(p_max_offers INTEGER DEFAULT 50)
RETURNS TABLE (
  id UUID,
  created_at TIMESTAMPTZ,
  fixer_id UUID,
  booking_id UUID,
  metadata JSONB,
  fixer_user_id UUID,
  fixer_email TEXT,
  booking_category TEXT,
  customer_city TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH target_offers AS (
    SELECT o.id
    FROM offers o
    WHERE o.status = 'pending'
      AND o.metadata->>'email_pending' = 'true'
      AND o.metadata->>'email_sent' IS NULL
      AND o.metadata->>'claimed_at' IS NULL
    ORDER BY o.created_at ASC
    LIMIT p_max_offers
  )
  UPDATE offers o
  SET metadata = jsonb_set(
    o.metadata,
    '{claimed_at}',
    to_jsonb(now())
  )
  FROM fixers f
  JOIN profiles fp ON f.user_id = fp.id
  JOIN bookings b ON o.booking_id = b.id
  JOIN profiles cp ON b.customer_id = cp.id
  JOIN target_offers tgt ON o.id = tgt.id
  WHERE o.fixer_id = f.id
  RETURNING
    o.id,
    o.created_at,
    o.fixer_id,
    o.booking_id,
    o.metadata,
    f.user_id AS fixer_user_id,
    fp.email AS fixer_email,
    b.category AS booking_category,
    cp.city AS customer_city;
END;
$$;

-- ── 5. Migration tracking ─────────────────────────────────────────
INSERT INTO schema_migrations (version) VALUES ('v8.9.9') ON CONFLICT DO NOTHING;
