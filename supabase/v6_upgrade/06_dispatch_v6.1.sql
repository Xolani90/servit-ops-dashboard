-- ═══════════════════════════════════════════════════════════════
-- SERVIT v6.1 — PATCH 1+2
-- Hard tier-based matching + sequential aggressive dispatch
--
-- BEFORE: All tiers used same scored query, same timeout, 
--         simultaneous broadcast to N fixers (passive)
--
-- AFTER:
--   BASIC    → ordered by price ASC, distance ASC, no verified filter
--              60s per fixer, 3 attempts
--   STANDARD → balanced score, 45s per fixer, 3 attempts  
--   PREMIUM  → verified only, ordered rating DESC + response ASC + 
--              completion DESC, 10s per fixer, 5 attempts
--
-- Sequential dispatch: ONE fixer notified at a time.
-- State stored in dispatch_log so cron/webhook can advance it.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Add dispatch_sequence column to track position ─────────
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS dispatch_sequence  INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS dispatch_fixer_id  UUID REFERENCES fixers(id),
  ADD COLUMN IF NOT EXISTS priority_flag      BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE dispatch_log
  ADD COLUMN IF NOT EXISTS sequence_position INTEGER,
  ADD COLUMN IF NOT EXISTS timeout_secs      INTEGER;

-- ── 2. Ranked fixer list builder (called once per booking) ────
CREATE OR REPLACE FUNCTION build_dispatch_queue(p_booking_id UUID)
RETURNS TABLE(fixer_id UUID, rank_position INTEGER, score NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking   bookings%ROWTYPE;
  v_tier      service_tier_enum;
  v_city      TEXT;
  v_lat       DOUBLE PRECISION;
  v_lng       DOUBLE PRECISION;
BEGIN
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN RETURN; END IF;

  v_tier := COALESCE(v_booking.service_tier, 'standard');
  v_lat  := v_booking.customer_latitude;
  v_lng  := v_booking.customer_longitude;
  SELECT p.city INTO v_city FROM profiles p WHERE p.id = v_booking.customer_id;

  IF v_tier = 'basic' THEN
    -- ORDER: cheapest first, then closest. No verified filter.
    RETURN QUERY
    SELECT
      f.id,
      ROW_NUMBER() OVER (
        ORDER BY
          COALESCE(f.price, 9999) ASC,
          CASE
            WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL
            THEN 2*6371*asin(sqrt(
              power(sin(radians((f.latitude-v_lat)/2)),2)+
              cos(radians(v_lat))*cos(radians(f.latitude))*
              power(sin(radians((f.longitude-v_lng)/2)),2)))
            ELSE 50
          END ASC,
          f.rating DESC NULLS LAST
      )::INTEGER,
      (100.0 - COALESCE(f.price,999)/10.0)::NUMERIC AS score
    FROM fixers f
    WHERE f.status      = 'approved'
      AND f.fixer_status = 'online'
      AND f.last_seen_at >= now() - interval '5 minutes'
      AND (f.city = v_city OR (f.latitude IS NOT NULL AND v_lat IS NOT NULL))
      AND (
        v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id = f.id AND fc.category = v_booking.category)
      )
      AND NOT EXISTS (
        SELECT 1 FROM dispatch_log dl
        WHERE dl.booking_id = p_booking_id AND dl.fixer_id = f.id
          AND dl.status IN ('notified','accepted')
      )
    LIMIT 5;

  ELSIF v_tier = 'premium' THEN
    -- ORDER: rating DESC, response time ASC, completion rate DESC.
    -- FILTER: verified = true, rating >= 4.0, completion_rate >= 80
    RETURN QUERY
    SELECT
      f.id,
      ROW_NUMBER() OVER (
        ORDER BY
          COALESCE(f.rating, 0)              DESC,
          COALESCE(f.response_time_avg, 9999) ASC,
          COALESCE(f.completion_rate, 0)      DESC
      )::INTEGER,
      (
        COALESCE(f.rating,0)*20 +
        GREATEST(0, 100 - COALESCE(f.response_time_avg,300)/3) +
        COALESCE(f.completion_rate,0)
      )::NUMERIC AS score
    FROM fixers f
    WHERE f.status      = 'approved'
      AND f.fixer_status = 'online'
      AND f.last_seen_at >= now() - interval '3 minutes'
      AND f.is_verified  = true
      AND COALESCE(f.rating, 0)           >= 4.0
      AND COALESCE(f.completion_rate, 0)  >= 80
      AND (f.city = v_city OR (f.latitude IS NOT NULL AND v_lat IS NOT NULL))
      AND (
        v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id = f.id AND fc.category = v_booking.category)
      )
      AND NOT EXISTS (
        SELECT 1 FROM dispatch_log dl
        WHERE dl.booking_id = p_booking_id AND dl.fixer_id = f.id
      )
    LIMIT 8;  -- more candidates for premium

  ELSE -- standard
    RETURN QUERY
    SELECT
      f.id,
      ROW_NUMBER() OVER (
        ORDER BY
          (
            COALESCE(f.rating,3)/5.0 * 0.40 +
            GREATEST(0,1.0 - CASE
              WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL
              THEN 2*6371*asin(sqrt(
                power(sin(radians((f.latitude-v_lat)/2)),2)+
                cos(radians(v_lat))*cos(radians(f.latitude))*
                power(sin(radians((f.longitude-v_lng)/2)),2)))
              ELSE 25 END / 25.0) * 0.35 +
            COALESCE(f.acceptance_rate,80)/100.0 * 0.25
          ) DESC
      )::INTEGER,
      (
        COALESCE(f.rating,3)/5.0 * 40 +
        COALESCE(f.acceptance_rate,80)/100.0 * 30 +
        GREATEST(0, 30 - COALESCE(f.response_time_avg,120)/10)
      )::NUMERIC AS score
    FROM fixers f
    WHERE f.status       = 'approved'
      AND f.fixer_status  = 'online'
      AND f.last_seen_at >= now() - interval '4 minutes'
      AND (f.city = v_city OR (f.latitude IS NOT NULL AND v_lat IS NOT NULL))
      AND (
        v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id = f.id AND fc.category = v_booking.category)
      )
      AND NOT EXISTS (
        SELECT 1 FROM dispatch_log dl
        WHERE dl.booking_id = p_booking_id AND dl.fixer_id = f.id
      )
    LIMIT 6;
  END IF;
END;
$$;

-- ── 3. Sequential dispatch: notify next fixer in queue ────────
CREATE OR REPLACE FUNCTION dispatch_next_fixer(p_booking_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking        bookings%ROWTYPE;
  v_tier           service_tier_enum;
  v_timeout_secs   INTEGER;
  v_max_attempts   INTEGER;
  v_next           RECORD;
  v_offer_id       UUID;
  v_expires_at     TIMESTAMPTZ;
  v_seq            INTEGER;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','Booking not found'); END IF;

  IF v_booking.status NOT IN ('SEARCHING','OFFERED') THEN
    RETURN jsonb_build_object('error', 'Booking not dispatchable', 'status', v_booking.status);
  END IF;

  v_tier := COALESCE(v_booking.service_tier, 'standard');

  -- Per-tier timeout and max attempts
  CASE v_tier
    WHEN 'basic'   THEN v_timeout_secs := 60; v_max_attempts := 3;
    WHEN 'premium' THEN v_timeout_secs := 10; v_max_attempts := 6;
    ELSE                v_timeout_secs := 30; v_max_attempts := 4;
  END CASE;

  -- If priority flagged, halve the timeout
  IF v_booking.priority_flag THEN
    v_timeout_secs := GREATEST(8, v_timeout_secs / 2);
  END IF;

  v_seq := COALESCE(v_booking.dispatch_sequence, 0);

  -- Check max attempts exhausted → fallback to offer system
  IF v_seq >= v_max_attempts THEN
    RETURN jsonb_build_object(
      'action',     'fallback',
      'booking_id', p_booking_id,
      'reason',     'max_attempts_reached',
      'attempts',   v_seq
    );
  END IF;

  -- Get next fixer from ranked queue (skips already tried)
  SELECT * INTO v_next
  FROM build_dispatch_queue(p_booking_id)
  ORDER BY rank_position
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'action',     'fallback',
      'booking_id', p_booking_id,
      'reason',     'no_eligible_fixers',
      'attempts',   v_seq
    );
  END IF;

  v_expires_at := now() + (v_timeout_secs || ' seconds')::interval;

  -- Expire any currently pending offer for this booking
  UPDATE offers SET status = 'expired', responded_at = now()
  WHERE booking_id = p_booking_id AND status = 'pending';

  -- Create new targeted offer
  INSERT INTO offers (booking_id, fixer_id, expires_at)
  VALUES (p_booking_id, v_next.fixer_id, v_expires_at)
  ON CONFLICT (booking_id, fixer_id) DO UPDATE SET
    status     = 'pending',
    expires_at = v_expires_at,
    responded_at = NULL
  RETURNING id INTO v_offer_id;

  -- Log dispatch attempt
  INSERT INTO dispatch_log (booking_id, fixer_id, status, score, tier, sequence_position, timeout_secs)
  VALUES (p_booking_id, v_next.fixer_id, 'notified', v_next.score, v_tier, v_seq + 1, v_timeout_secs)
  ON CONFLICT DO NOTHING;

  -- Advance sequence counter + record current fixer
  UPDATE bookings SET
    dispatch_sequence = v_seq + 1,
    dispatch_fixer_id = v_next.fixer_id,
    dispatch_at       = now(),
    dispatch_expiry   = v_expires_at,
    status            = 'OFFERED',
    offered_at        = COALESCE(offered_at, now()),
    offer_expires_at  = v_expires_at,
    current_offer_id  = v_offer_id,
    updated_at        = now(),
    version           = version + 1
  WHERE id = p_booking_id;

  -- Notify fixer with tier-appropriate urgency
  INSERT INTO notifications (user_id, title, body, type, related_id)
  SELECT
    f.user_id,
    CASE v_tier
      WHEN 'premium' THEN '⭐ Priority job — respond now!'
      WHEN 'basic'   THEN '💼 Job offer near you'
      ELSE                '🔔 New job offer!'
    END,
    'Job: ' || COALESCE(v_booking.category,'General') ||
    ' · You have ' || v_timeout_secs || 's to accept.',
    'job_offer',
    v_offer_id
  FROM fixers f WHERE f.id = v_next.fixer_id;

  RETURN jsonb_build_object(
    'action',        'dispatched',
    'booking_id',    p_booking_id,
    'fixer_id',      v_next.fixer_id,
    'offer_id',      v_offer_id,
    'sequence',      v_seq + 1,
    'expires_at',    v_expires_at,
    'timeout_secs',  v_timeout_secs,
    'tier',          v_tier
  );
END;
$$;

-- ── 4. Cron: advance expired sequential dispatches ────────────
-- Runs every 15 seconds via pg_cron (set up in Supabase dashboard)
CREATE OR REPLACE FUNCTION advance_expired_dispatches()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking   RECORD;
  v_result    JSONB;
  v_advanced  INTEGER := 0;
BEGIN
  -- Find bookings with expired current dispatch offer
  FOR v_booking IN
    SELECT b.id, b.service_tier, b.dispatch_sequence, b.priority_flag
    FROM bookings b
    WHERE b.status = 'OFFERED'
      AND b.dispatch_expiry < now()
      AND b.dispatch_mode != 'manual'
    FOR UPDATE SKIP LOCKED
  LOOP
    -- Mark current dispatch log entry timed_out
    UPDATE dispatch_log SET status = 'timed_out', responded_at = now()
    WHERE booking_id = v_booking.id
      AND status     = 'notified'
      AND sequence_position = v_booking.dispatch_sequence;

    -- Expire the pending offer
    UPDATE offers SET status = 'expired', responded_at = now()
    WHERE booking_id = v_booking.id AND status = 'pending';

    -- Try next fixer
    v_result := dispatch_next_fixer(v_booking.id);

    IF (v_result->>'action') = 'fallback' THEN
      -- Exhausted — reset to SEARCHING for offer-mode fallback
      UPDATE bookings SET
        status            = 'SEARCHING',
        dispatch_sequence = 0,
        dispatch_fixer_id = NULL,
        updated_at        = now(),
        version           = version + 1
      WHERE id = v_booking.id;

      -- Alert admin if no fixer found
      INSERT INTO notifications (user_id, title, body, type, related_id)
      SELECT p.id, '🚨 Job unmatched — needs attention',
        'Booking ' || v_booking.id::TEXT || ' exhausted all dispatch attempts.',
        'admin_alert', v_booking.id
      FROM profiles p WHERE p.user_role = 'admin';
    END IF;

    v_advanced := v_advanced + 1;
  END LOOP;

  RETURN v_advanced;
END;
$$;

-- ── 5. Kickoff: replace match_fixers entry point ──────────────
-- match_fixers now just calls dispatch_next_fixer to start chain
CREATE OR REPLACE FUNCTION match_fixers(
  p_booking_id UUID,
  p_radius_km  DOUBLE PRECISION DEFAULT 25.0,
  p_batch_size INTEGER          DEFAULT 3
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking bookings%ROWTYPE;
  v_result  JSONB;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','Booking not found'); END IF;

  IF v_booking.status != 'SEARCHING' OR v_booking.payment_status != 'paid' THEN
    RETURN jsonb_build_object('error','Booking not available for matching');
  END IF;

  IF v_booking.booking_mode = 'scheduled'
     AND v_booking.scheduled_for > now() + interval '2 hours' THEN
    RETURN jsonb_build_object('error','Scheduled booking not ready for matching');
  END IF;

  -- Reset sequence for fresh dispatch
  UPDATE bookings SET dispatch_sequence = 0, dispatch_at = now()
  WHERE id = p_booking_id;

  v_result := dispatch_next_fixer(p_booking_id);

  -- If no fixers at all, broadcast demand alert
  IF (v_result->>'action') = 'fallback' THEN
    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT f.user_id,
      '💼 Job available near you!',
      'Client needs ' || COALESCE(v_booking.category,'help') || '. Go online to accept.',
      'demand_alert', p_booking_id
    FROM fixers f
    JOIN profiles p ON p.id = v_booking.customer_id
    WHERE f.status = 'approved' AND f.city = p.city
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.user_id = f.user_id AND n.related_id = p_booking_id AND n.type = 'demand_alert'
      );

    RETURN jsonb_build_object('error','No fixers available','broadcast',true,'booking_id',p_booking_id);
  END IF;

  RETURN v_result;
END;
$$;

-- ── 6. Cron job (add in Supabase dashboard) ───────────────────
-- SELECT cron.schedule('advance-dispatch', '15 seconds', $$SELECT advance_expired_dispatches()$$);

GRANT EXECUTE ON FUNCTION build_dispatch_queue(UUID)    TO service_role;
GRANT EXECUTE ON FUNCTION dispatch_next_fixer(UUID)     TO service_role;
GRANT EXECUTE ON FUNCTION advance_expired_dispatches()  TO service_role;
GRANT EXECUTE ON FUNCTION match_fixers(UUID, DOUBLE PRECISION, INTEGER) TO service_role;
