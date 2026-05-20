-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8.9.4 — Structured Logging for Booking State Transitions
-- 
-- STEP 4: Add structured logging for every booking state transition
-- with booking_id tracing for observability and debugging
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Create structured logging table ───────────────────────────
CREATE TABLE IF NOT EXISTS booking_transition_logs (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id      UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  event_type      TEXT NOT NULL,
  old_status      booking_status_enum,
  new_status      booking_status_enum,
  payment_status  payment_status_enum,
  actor_user_id   UUID REFERENCES auth.users(id),
  actor_role      TEXT,
  source          TEXT NOT NULL, -- 'webhook', 'api', 'cron', 'rpc'
  metadata        JSONB,
  duration_ms     INTEGER, -- For performance tracking
  error_message   TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- Index for querying by booking_id
CREATE INDEX idx_booking_transition_logs_booking_id ON booking_transition_logs(booking_id);
CREATE INDEX idx_booking_transition_logs_created_at ON booking_transition_logs(created_at);
CREATE INDEX idx_booking_transition_logs_event_type ON booking_transition_logs(event_type);

-- ── 2. Create helper function for structured logging ─────────────
CREATE OR REPLACE FUNCTION log_booking_transition(
  p_booking_id      UUID,
  p_event_type      TEXT,
  p_old_status      booking_status_enum DEFAULT NULL,
  p_new_status      booking_status_enum DEFAULT NULL,
  p_payment_status  payment_status_enum DEFAULT NULL,
  p_actor_user_id   UUID DEFAULT NULL,
  p_source          TEXT DEFAULT 'rpc',
  p_metadata        JSONB DEFAULT '{}'::jsonb,
  p_error_message   TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_log_id UUID;
  v_actor_role TEXT;
BEGIN
  -- Determine actor role if user_id provided
  IF p_actor_user_id IS NOT NULL THEN
    SELECT user_role INTO v_actor_role
    FROM profiles
    WHERE id = p_actor_user_id;
  END IF;

  INSERT INTO booking_transition_logs (
    booking_id,
    event_type,
    old_status,
    new_status,
    payment_status,
    actor_user_id,
    actor_role,
    source,
    metadata,
    error_message
  ) VALUES (
    p_booking_id,
    p_event_type,
    p_old_status,
    p_new_status,
    p_payment_status,
    p_actor_user_id,
    v_actor_role,
    p_source,
    p_metadata,
    p_error_message
  ) RETURNING id INTO v_log_id;

  RETURN v_log_id;
END;
$$;

-- ── 3. Update match_fixers to use structured logging ───────────────
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

-- ── 4. Update accept_offer to use structured logging ───────────────
CREATE OR REPLACE FUNCTION accept_offer(
  p_offer_id      UUID,
  p_fixer_id      UUID,
  p_fixer_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offer        offers%ROWTYPE;
  v_booking      bookings%ROWTYPE;
  v_verify_owner UUID;
  v_losing_fixer RECORD;
  v_start_time   TIMESTAMPTZ := now();
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  PERFORM log_booking_transition(
    p_booking_id => p_offer_id, -- Will be updated after we get booking_id
    p_event_type => 'accept_offer_start',
    p_actor_user_id => p_fixer_user_id,
    p_source => 'rpc',
    p_metadata => jsonb_build_object('offer_id', p_offer_id, 'fixer_id', p_fixer_id)
  );

  SELECT user_id INTO v_verify_owner FROM fixers WHERE id = p_fixer_id;

  IF v_verify_owner IS NULL OR v_verify_owner != p_fixer_user_id THEN
    PERFORM log_booking_transition(
      p_booking_id => p_offer_id,
      p_event_type => 'accept_offer_error',
      p_actor_user_id => p_fixer_user_id,
      p_source => 'rpc',
      p_error_message => 'Unauthorized: fixer does not own this offer'
    );
    RAISE EXCEPTION 'Unauthorized: fixer does not own this offer';
  END IF;

  SELECT * INTO v_offer FROM offers WHERE id = p_offer_id FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM log_booking_transition(
      p_booking_id => p_offer_id,
      p_event_type => 'accept_offer_error',
      p_actor_user_id => p_fixer_user_id,
      p_source => 'rpc',
      p_error_message => 'Offer not found'
    );
    RAISE EXCEPTION 'Offer not found';
  END IF;

  IF v_offer.status != 'pending' THEN
    PERFORM log_booking_transition(
      p_booking_id => v_offer.booking_id,
      p_event_type => 'accept_offer_error',
      p_actor_user_id => p_fixer_user_id,
      p_source => 'rpc',
      p_error_message => 'Offer already ' || v_offer.status
    );
    RAISE EXCEPTION 'Offer already %', v_offer.status;
  END IF;

  IF v_offer.expires_at < now() THEN
    UPDATE offers SET status = 'expired' WHERE id = p_offer_id;
    PERFORM log_booking_transition(
      p_booking_id => v_offer.booking_id,
      p_event_type => 'accept_offer_error',
      p_actor_user_id => p_fixer_user_id,
      p_source => 'rpc',
      p_error_message => 'Offer has expired'
    );
    RAISE EXCEPTION 'Offer has expired';
  END IF;

  SELECT * INTO v_booking FROM bookings WHERE id = v_offer.booking_id FOR UPDATE;

  IF v_booking.status != 'OFFERED' THEN
    PERFORM log_booking_transition(
      p_booking_id => v_booking.id,
      p_event_type => 'accept_offer_error',
      p_old_status => v_booking.status,
      p_actor_user_id => p_fixer_user_id,
      p_source => 'rpc',
      p_error_message => 'Booking is not in OFFERED state'
    );
    RAISE EXCEPTION 'Booking is not in OFFERED state (current: %)', v_booking.status;
  END IF;

  UPDATE offers SET
    status       = 'accepted',
    responded_at = now()
  WHERE id = p_offer_id;

  UPDATE bookings SET
    status           = 'CONFIRMED',
    fixer_id         = v_offer.fixer_id,
    confirmed_at     = now(),
    current_offer_id = p_offer_id,
    updated_at       = now(),
    version          = version + 1
  WHERE id = v_booking.id;

  UPDATE fixers SET
    available  = false,
    updated_at = now()
  WHERE id = v_offer.fixer_id;

  FOR v_losing_fixer IN
    SELECT o.id AS offer_id, f.user_id AS fixer_user_id
    FROM   offers o
    JOIN   fixers f ON f.id = o.fixer_id
    WHERE  o.booking_id = v_booking.id
      AND  o.id        != p_offer_id
      AND  o.status     = 'pending'
    FOR UPDATE OF o SKIP LOCKED
  LOOP
    UPDATE offers SET
      status       = 'expired',
      responded_at = now()
    WHERE id = v_losing_fixer.offer_id;

    INSERT INTO notifications (user_id, title, body, type, related_id)
    VALUES (
      v_losing_fixer.fixer_user_id,
      '⚡ Job taken',
      'Another fixer accepted this job first. Stay available for the next one!',
      'offer_expired',
      v_booking.id
    );
  END LOOP;

  INSERT INTO booking_events (
    booking_id, event_type, old_status, new_status, metadata, created_by
  ) VALUES (
    v_booking.id, 'offer_accepted', 'OFFERED', 'CONFIRMED',
    jsonb_build_object('offer_id', p_offer_id, 'fixer_id', v_offer.fixer_id),
    p_fixer_user_id
  );

  PERFORM log_booking_transition(
    p_booking_id => v_booking.id,
    p_event_type => 'offer_accepted',
    p_old_status => 'OFFERED',
    p_new_status => 'CONFIRMED',
    p_actor_user_id => p_fixer_user_id,
    p_source => 'rpc',
    p_metadata => jsonb_build_object(
      'offer_id', p_offer_id,
      'fixer_id', v_offer.fixer_id,
      'duration_ms', EXTRACT(EPOCH FROM (now() - v_start_time)) * 1000
    )
  );

  RETURN jsonb_build_object(
    'success',    true,
    'booking_id', v_booking.id,
    'status',     'CONFIRMED',
    'fixer_id',   v_offer.fixer_id
  );
END;
$$;

-- ── 5. Update update_job_status to use structured logging ───────────
CREATE OR REPLACE FUNCTION update_job_status(
  p_booking_id    UUID,
  p_actor_user_id UUID,
  p_new_status   TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking    bookings%ROWTYPE;
  v_old_status booking_status_enum;
  v_start_time TIMESTAMPTZ := now();
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  PERFORM log_booking_transition(
    p_booking_id => p_booking_id,
    p_event_type => 'update_job_status_start',
    p_actor_user_id => p_actor_user_id,
    p_source => 'rpc',
    p_metadata => jsonb_build_object('new_status', p_new_status)
  );

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM log_booking_transition(
      p_booking_id => p_booking_id,
      p_event_type => 'update_job_status_error',
      p_actor_user_id => p_actor_user_id,
      p_source => 'rpc',
      p_error_message => 'Booking not found'
    );
    RAISE EXCEPTION 'Booking not found';
  END IF;

  v_old_status := v_booking.status;

  -- Validate state transition
  IF NOT validate_booking_transition(v_old_status, p_new_status::booking_status_enum) THEN
    PERFORM log_booking_transition(
      p_booking_id => p_booking_id,
      p_event_type => 'update_job_status_error',
      p_old_status => v_old_status,
      p_new_status => p_new_status::booking_status_enum,
      p_actor_user_id => p_actor_user_id,
      p_source => 'rpc',
      p_error_message => 'Invalid state transition'
    );
    RAISE EXCEPTION 'Invalid state transition from % to %', v_old_status, p_new_status;
  END IF;

  -- Update status based on new status
  CASE p_new_status
    WHEN 'EN_ROUTE' THEN
      UPDATE bookings SET
        status = 'EN_ROUTE',
        en_route_at = now(),
        updated_at = now(),
        version = version + 1
      WHERE id = p_booking_id;
    WHEN 'ARRIVED' THEN
      UPDATE bookings SET
        status = 'ARRIVED',
        arrived_at = now(),
        updated_at = now(),
        version = version + 1
      WHERE id = p_booking_id;
    WHEN 'IN_PROGRESS' THEN
      UPDATE bookings SET
        status = 'IN_PROGRESS',
        in_progress_at = now(),
        updated_at = now(),
        version = version + 1
      WHERE id = p_booking_id;
    WHEN 'PENDING_COMPLETION' THEN
      UPDATE bookings SET
        status = 'PENDING_COMPLETION',
        pending_completion_at = now(),
        updated_at = now(),
        version = version + 1
      WHERE id = p_booking_id;
    WHEN 'COMPLETED' THEN
      UPDATE bookings SET
        status = 'COMPLETED',
        completed_at = now(),
        updated_at = now(),
        version = version + 1
      WHERE id = p_booking_id;
  END CASE;

  INSERT INTO booking_events (
    booking_id, event_type, old_status, new_status, created_by
  ) VALUES (
    p_booking_id, 'status_updated', v_old_status, p_new_status::booking_status_enum, p_actor_user_id
  );

  PERFORM log_booking_transition(
    p_booking_id => p_booking_id,
    p_event_type => 'status_updated',
    p_old_status => v_old_status,
    p_new_status => p_new_status::booking_status_enum,
    p_actor_user_id => p_actor_user_id,
    p_source => 'rpc',
    p_metadata => jsonb_build_object(
      'duration_ms', EXTRACT(EPOCH FROM (now() - v_start_time)) * 1000
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'status', p_new_status
  );
END;
$$;

-- ── 6. Migration tracking ─────────────────────────────────────────
INSERT INTO schema_migrations (version) VALUES ('v8.9.4_logging') ON CONFLICT DO NOTHING;
