-- ═══════════════════════════════════════════════════════════════
-- SERVIT v6.2 — 7-Issue Patch
-- 1. Normalized scoring (0→1 scale, no skew)
-- 2. Atomic assignment guard (race condition fix)
-- 3. Dynamic timeout (tier + time-of-day)
-- 4. Multi-pass dispatch for PREMIUM
-- 5. Behavioral penalties (ignore/cancel)
-- 6. Dynamic badges (vs system median)
-- 7. Early warning system (proactive, not reactive)
-- ═══════════════════════════════════════════════════════════════

-- ── Schema additions ──────────────────────────────────────────
ALTER TABLE fixers
  ADD COLUMN IF NOT EXISTS ignore_count      INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cancel_penalty    NUMERIC(5,2) NOT NULL DEFAULT 0.0,
  ADD COLUMN IF NOT EXISTS dispatch_pass     INTEGER NOT NULL DEFAULT 1;

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS dispatch_pass     INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS early_warned_at   TIMESTAMPTZ;

-- ── FIX 1+4: Normalized scoring + multi-pass queue builder ────
CREATE OR REPLACE FUNCTION build_dispatch_queue(
  p_booking_id UUID,
  p_pass       INTEGER DEFAULT 1
)
RETURNS TABLE(fixer_id UUID, rank_position INTEGER, score NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking   bookings%ROWTYPE;
  v_tier      service_tier_enum;
  v_lat       DOUBLE PRECISION;
  v_lng       DOUBLE PRECISION;
  v_city      TEXT;
  -- Normalization bounds
  v_max_price    NUMERIC;
  v_min_price    NUMERIC;
  v_max_dist     NUMERIC := 25.0;  -- km radius cap
  v_max_resp     NUMERIC := 300.0; -- seconds cap
  -- Dynamic badge thresholds (system median)
  v_median_resp  NUMERIC;
  v_median_comp  NUMERIC;
BEGIN
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN RETURN; END IF;

  v_tier := COALESCE(v_booking.service_tier, 'standard');
  v_lat  := v_booking.customer_latitude;
  v_lng  := v_booking.customer_longitude;
  SELECT p.city INTO v_city FROM profiles p WHERE p.id = v_booking.customer_id;

  -- ── Compute normalization bounds from live fixer pool ───────
  SELECT
    COALESCE(MAX(f.price), 1000),
    COALESCE(MIN(f.price), 0)
  INTO v_max_price, v_min_price
  FROM fixers f WHERE f.status = 'approved' AND f.fixer_status = 'online';

  -- Avoid division by zero if all same price
  IF v_max_price = v_min_price THEN v_max_price := v_min_price + 1; END IF;

  -- ────────────────────────────────────────────────────────────
  --  BASIC — Pass 1: cheap+close, Pass 2: wider pool same order
  -- ────────────────────────────────────────────────────────────
  IF v_tier = 'basic' THEN
    RETURN QUERY
    WITH candidates AS (
      SELECT
        f.*,
        -- FIX 1: normalized price score (cheaper = higher score)
        CASE WHEN v_max_price > v_min_price
          THEN (v_max_price - COALESCE(f.price, v_max_price)) / (v_max_price - v_min_price)
          ELSE 0.5 END AS norm_price,
        -- FIX 1: normalized distance score (closer = higher)
        CASE
          WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL
          THEN GREATEST(0, 1.0 - (
            2*6371*asin(sqrt(
              power(sin(radians((f.latitude-v_lat)/2)),2)+
              cos(radians(v_lat))*cos(radians(f.latitude))*
              power(sin(radians((f.longitude-v_lng)/2)),2)
            ))
          ) / v_max_dist)
          ELSE 0.5 END AS norm_dist
      FROM fixers f
      WHERE f.status       = 'approved'
        AND f.fixer_status  = 'online'
        AND f.last_seen_at >= now() - interval '5 minutes'
        AND (f.city = v_city OR (f.latitude IS NOT NULL AND v_lat IS NOT NULL))
        AND (
          v_booking.category IS NULL
          OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
          OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id=f.id AND fc.category=v_booking.category)
        )
        AND NOT EXISTS (
          SELECT 1 FROM dispatch_log dl
          WHERE dl.booking_id = p_booking_id AND dl.fixer_id = f.id
        )
        -- Pass 2 loosens acceptance_rate filter
        AND (p_pass >= 2 OR COALESCE(f.acceptance_rate, 100) >= 50)
    )
    SELECT
      c.id,
      ROW_NUMBER() OVER (ORDER BY
        -- FIX 1: weights applied to normalized 0→1 values
        (c.norm_price * 0.55 + c.norm_dist * 0.35 +
         COALESCE(c.rating,3)/5.0 * 0.10) DESC
      )::INTEGER,
      (c.norm_price * 0.55 + c.norm_dist * 0.35 + COALESCE(c.rating,3)/5.0 * 0.10) AS score
    FROM candidates c
    LIMIT CASE WHEN p_pass = 1 THEN 4 ELSE 6 END;

  -- ────────────────────────────────────────────────────────────
  --  STANDARD — Pass 1: balanced, Pass 2: wider acceptance rate
  -- ────────────────────────────────────────────────────────────
  ELSIF v_tier = 'standard' THEN
    RETURN QUERY
    WITH candidates AS (
      SELECT
        f.*,
        CASE WHEN v_max_price > v_min_price
          THEN (v_max_price - COALESCE(f.price, v_max_price)) / (v_max_price - v_min_price)
          ELSE 0.5 END AS norm_price,
        CASE
          WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL
          THEN GREATEST(0, 1.0 - (
            2*6371*asin(sqrt(
              power(sin(radians((f.latitude-v_lat)/2)),2)+
              cos(radians(v_lat))*cos(radians(f.latitude))*
              power(sin(radians((f.longitude-v_lng)/2)),2)
            ))
          ) / v_max_dist)
          ELSE 0.5 END AS norm_dist,
        COALESCE(f.rating, 3.0) / 5.0 AS norm_rating,
        COALESCE(f.acceptance_rate, 80) / 100.0 AS norm_acc,
        -- FIX 1: normalize response time
        GREATEST(0, 1.0 - COALESCE(f.avg_response_time, 120)::NUMERIC / v_max_resp) AS norm_resp,
        -- FIX 5: cancel penalty applied as multiplier
        GREATEST(0.5, 1.0 - COALESCE(f.cancel_penalty, 0)) AS penalty_mult
      FROM fixers f
      WHERE f.status       = 'approved'
        AND f.fixer_status  = 'online'
        AND f.last_seen_at >= now() - interval '4 minutes'
        AND (f.city = v_city OR (f.latitude IS NOT NULL AND v_lat IS NOT NULL))
        AND (
          v_booking.category IS NULL
          OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
          OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id=f.id AND fc.category=v_booking.category)
        )
        AND NOT EXISTS (
          SELECT 1 FROM dispatch_log dl
          WHERE dl.booking_id = p_booking_id AND dl.fixer_id = f.id
        )
        AND (p_pass >= 2 OR COALESCE(f.acceptance_rate, 100) >= 60)
    )
    SELECT
      c.id,
      ROW_NUMBER() OVER (ORDER BY
        (c.norm_rating * 0.35 + c.norm_dist * 0.30 +
         c.norm_acc * 0.20 + c.norm_resp * 0.15) * c.penalty_mult DESC
      )::INTEGER,
      ((c.norm_rating * 0.35 + c.norm_dist * 0.30 +
        c.norm_acc * 0.20 + c.norm_resp * 0.15) * c.penalty_mult) AS score
    FROM candidates c
    LIMIT CASE WHEN p_pass = 1 THEN 4 ELSE 6 END;

  -- ────────────────────────────────────────────────────────────
  --  PREMIUM — 3 passes: verified elite → verified broad → unverified high performers
  -- ────────────────────────────────────────────────────────────
  ELSE
    RETURN QUERY
    WITH candidates AS (
      SELECT
        f.*,
        COALESCE(f.rating, 3.0) / 5.0 AS norm_rating,
        -- FIX 1: normalized response time
        GREATEST(0, 1.0 - COALESCE(f.avg_response_time, 120)::NUMERIC / v_max_resp) AS norm_resp,
        COALESCE(f.completion_rate, 80) / 100.0 AS norm_comp,
        CASE
          WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL
          THEN GREATEST(0, 1.0 - (
            2*6371*asin(sqrt(
              power(sin(radians((f.latitude-v_lat)/2)),2)+
              cos(radians(v_lat))*cos(radians(f.latitude))*
              power(sin(radians((f.longitude-v_lng)/2)),2)
            ))
          ) / v_max_dist)
          ELSE 0.5 END AS norm_dist,
        -- FIX 5: heavy cancel penalty for premium
        GREATEST(0.3, 1.0 - COALESCE(f.cancel_penalty, 0) * 1.5) AS penalty_mult
      FROM fixers f
      WHERE f.status       = 'approved'
        AND f.fixer_status  = 'online'
        AND f.last_seen_at >= now() - interval '3 minutes'
        AND (f.city = v_city OR (f.latitude IS NOT NULL AND v_lat IS NOT NULL))
        AND (
          v_booking.category IS NULL
          OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
          OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id=f.id AND fc.category=v_booking.category)
        )
        AND NOT EXISTS (
          SELECT 1 FROM dispatch_log dl
          WHERE dl.booking_id = p_booking_id AND dl.fixer_id = f.id
        )
        -- FIX 4: multi-pass gates
        AND CASE
          WHEN p_pass = 1 THEN f.is_verified = true AND COALESCE(f.rating,0) >= 4.5 AND COALESCE(f.completion_rate,0) >= 90
          WHEN p_pass = 2 THEN f.is_verified = true AND COALESCE(f.rating,0) >= 4.0 AND COALESCE(f.completion_rate,0) >= 80
          WHEN p_pass = 3 THEN COALESCE(f.rating,0) >= 4.0 AND COALESCE(f.completion_rate,0) >= 75  -- opens to unverified
          ELSE true  -- pass 4+ : any available fixer
        END
    )
    SELECT
      c.id,
      ROW_NUMBER() OVER (ORDER BY
        (c.norm_rating * 0.45 + c.norm_resp * 0.30 +
         c.norm_comp * 0.15  + c.norm_dist * 0.10) * c.penalty_mult DESC
      )::INTEGER,
      ((c.norm_rating * 0.45 + c.norm_resp * 0.30 +
        c.norm_comp * 0.15  + c.norm_dist * 0.10) * c.penalty_mult) AS score
    FROM candidates c
    LIMIT CASE
      WHEN p_pass = 1 THEN 3
      WHEN p_pass = 2 THEN 4
      ELSE 5
    END;
  END IF;
END;
$$;

-- ── FIX 3: Dynamic timeout (tier + time-of-day) ───────────────
CREATE OR REPLACE FUNCTION get_dispatch_timeout(
  p_tier     service_tier_enum,
  p_priority BOOLEAN DEFAULT false
)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_hour    INTEGER := EXTRACT(HOUR FROM now() AT TIME ZONE 'Africa/Johannesburg');
  v_base    INTEGER;
  v_mult    NUMERIC := 1.0;
BEGIN
  -- Base timeout per tier
  CASE p_tier
    WHEN 'basic'   THEN v_base := 25;   -- 20–30s range
    WHEN 'premium' THEN v_base := 10;   -- 8–12s range
    ELSE                v_base := 18;   -- 15–20s range
  END CASE;

  -- Time-of-day multiplier (low activity = more time)
  CASE
    WHEN v_hour BETWEEN 0  AND 5  THEN v_mult := 2.0;  -- overnight: double
    WHEN v_hour BETWEEN 6  AND 8  THEN v_mult := 1.4;  -- early morning
    WHEN v_hour BETWEEN 9  AND 17 THEN v_mult := 1.0;  -- peak hours: standard
    WHEN v_hour BETWEEN 18 AND 21 THEN v_mult := 1.2;  -- evening: slightly more
    ELSE                                v_mult := 1.6;  -- late night
  END CASE;

  -- Priority flag halves it
  IF p_priority THEN v_mult := v_mult * 0.5; END IF;

  RETURN GREATEST(8, ROUND(v_base * v_mult)::INTEGER);
END;
$$;

-- ── FIX 2+4: Atomic dispatch with pass tracking ───────────────
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
  v_max_passes     INTEGER;
  v_next           RECORD;
  v_offer_id       UUID;
  v_expires_at     TIMESTAMPTZ;
  v_seq            INTEGER;
  v_pass           INTEGER;
  v_rows           INTEGER;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  -- FIX 2: Strong row-level lock
  SELECT * INTO v_booking
  FROM bookings WHERE id = p_booking_id
  FOR UPDATE SKIP LOCKED;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Booking locked or not found');
  END IF;

  IF v_booking.status NOT IN ('SEARCHING','OFFERED') THEN
    RETURN jsonb_build_object('error', 'Not dispatchable', 'status', v_booking.status);
  END IF;

  v_tier := COALESCE(v_booking.service_tier, 'standard');
  v_seq  := COALESCE(v_booking.dispatch_sequence, 0);
  v_pass := COALESCE(v_booking.dispatch_pass, 1);

  -- FIX 3: dynamic timeout
  v_timeout_secs := get_dispatch_timeout(v_tier, v_booking.priority_flag);

  -- Max attempts per pass, max passes per tier
  CASE v_tier
    WHEN 'basic'   THEN v_max_attempts := 3; v_max_passes := 2;
    WHEN 'premium' THEN v_max_attempts := 3; v_max_passes := 4;  -- FIX 4: 4 passes
    ELSE                v_max_attempts := 3; v_max_passes := 2;
  END CASE;

  -- FIX 4: advance to next pass if current pass exhausted
  IF v_seq >= v_max_attempts * v_pass THEN
    v_pass := v_pass + 1;
    IF v_pass > v_max_passes THEN
      RETURN jsonb_build_object(
        'action',   'fallback',
        'booking_id', p_booking_id,
        'reason',   'all_passes_exhausted',
        'passes',   v_pass - 1,
        'attempts', v_seq
      );
    END IF;
    -- Reset per-pass attempt counter concept via pass bump
    UPDATE bookings SET dispatch_pass = v_pass WHERE id = p_booking_id;
  END IF;

  -- Get next fixer from this pass's ranked queue
  SELECT * INTO v_next
  FROM build_dispatch_queue(p_booking_id, v_pass)
  ORDER BY rank_position
  LIMIT 1;

  IF NOT FOUND THEN
    -- No fixers in this pass → try next pass immediately
    v_pass := v_pass + 1;
    IF v_pass > v_max_passes THEN
      RETURN jsonb_build_object(
        'action',   'fallback',
        'booking_id', p_booking_id,
        'reason',   'no_fixers_any_pass'
      );
    END IF;
    UPDATE bookings SET dispatch_pass = v_pass WHERE id = p_booking_id;
    SELECT * INTO v_next
    FROM build_dispatch_queue(p_booking_id, v_pass)
    ORDER BY rank_position LIMIT 1;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('action','fallback','booking_id',p_booking_id,'reason','no_eligible_fixers');
    END IF;
  END IF;

  v_expires_at := now() + (v_timeout_secs || ' seconds')::interval;

  -- FIX 2: Atomic offer upsert — only create if booking still unassigned
  UPDATE bookings SET
    dispatch_sequence = v_seq + 1,
    dispatch_pass     = v_pass,
    dispatch_fixer_id = v_next.fixer_id,
    dispatch_at       = now(),
    dispatch_expiry   = v_expires_at,
    status            = 'OFFERED',
    offered_at        = COALESCE(offered_at, now()),
    offer_expires_at  = v_expires_at,
    updated_at        = now(),
    version           = version + 1
  WHERE id = p_booking_id
    AND fixer_id IS NULL  -- FIX 2: atomic guard — already assigned? stop.
    AND status IN ('SEARCHING','OFFERED');

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RETURN jsonb_build_object(
      'action', 'already_assigned',
      'booking_id', p_booking_id
    );
  END IF;

  -- Expire prior pending offer
  UPDATE offers SET status = 'expired', responded_at = now()
  WHERE booking_id = p_booking_id AND status = 'pending'
    AND fixer_id != v_next.fixer_id;

  -- Create new offer
  INSERT INTO offers (booking_id, fixer_id, expires_at)
  VALUES (p_booking_id, v_next.fixer_id, v_expires_at)
  ON CONFLICT (booking_id, fixer_id) DO UPDATE SET
    status     = 'pending',
    expires_at = v_expires_at,
    responded_at = NULL
  RETURNING id INTO v_offer_id;

  UPDATE bookings SET current_offer_id = v_offer_id WHERE id = p_booking_id;

  -- Log dispatch
  INSERT INTO dispatch_log (booking_id, fixer_id, status, score, tier, sequence_position, timeout_secs)
  VALUES (p_booking_id, v_next.fixer_id, 'notified', v_next.score, v_tier, v_seq + 1, v_timeout_secs)
  ON CONFLICT DO NOTHING;

  -- FIX 7: early warning — alert admin after 2nd fixer for PREMIUM, 3rd for others
  DECLARE
    v_warn_after INTEGER := CASE v_tier WHEN 'premium' THEN 2 ELSE 3 END;
  BEGIN
    IF (v_seq + 1) >= v_warn_after AND v_booking.early_warned_at IS NULL THEN
      UPDATE bookings SET early_warned_at = now() WHERE id = p_booking_id;
      INSERT INTO notifications (user_id, title, body, type, related_id)
      SELECT p.id,
        CASE v_tier WHEN 'premium' THEN '⚠️ Premium job needs fixer — act now'
                    ELSE '⚠️ Job dispatch running long' END,
        CASE v_tier WHEN 'premium'
          THEN 'Premium booking ' || LEFT(p_booking_id::TEXT,8) ||
               ' (' || COALESCE(v_booking.category,'General') || ') on attempt #' || (v_seq+1) ||
               '. Consider manual assign.'
          ELSE 'Booking ' || LEFT(p_booking_id::TEXT,8) ||
               ' (' || COALESCE(v_booking.category,'General') || ') on attempt #' || (v_seq+1) || '.'
        END,
        'admin_early_warning',
        p_booking_id
      FROM profiles p WHERE p.user_role = 'admin';
    END IF;
  END;

  -- Notify fixer
  INSERT INTO notifications (user_id, title, body, type, related_id)
  SELECT f.user_id,
    CASE v_tier
      WHEN 'premium' THEN '⭐ Priority job — ' || v_timeout_secs || 's to accept!'
      WHEN 'basic'   THEN '💼 Job near you — ' || v_timeout_secs || 's'
      ELSE                '🔔 Job offer — ' || v_timeout_secs || 's to accept'
    END,
    COALESCE(v_booking.category,'General') || ' job · ' ||
    CASE v_pass WHEN 1 THEN '' ELSE '(Pass ' || v_pass || ') ' END ||
    'Tap to accept.',
    'job_offer', v_offer_id
  FROM fixers f WHERE f.id = v_next.fixer_id;

  RETURN jsonb_build_object(
    'action',       'dispatched',
    'booking_id',   p_booking_id,
    'fixer_id',     v_next.fixer_id,
    'offer_id',     v_offer_id,
    'sequence',     v_seq + 1,
    'pass',         v_pass,
    'expires_at',   v_expires_at,
    'timeout_secs', v_timeout_secs,
    'tier',         v_tier,
    'score',        v_next.score
  );
END;
$$;

-- ── FIX 2: Hardened accept_offer with atomic guard ────────────
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
  v_offer         offers%ROWTYPE;
  v_booking       bookings%ROWTYPE;
  v_verify_owner  UUID;
  v_losing_fixer  RECORD;
  v_dispatch_time TIMESTAMPTZ;
  v_response_secs INTEGER;
  v_rows          INTEGER;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT user_id INTO v_verify_owner FROM fixers WHERE id = p_fixer_id;
  IF v_verify_owner IS NULL OR v_verify_owner != p_fixer_user_id THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT * INTO v_offer FROM offers WHERE id = p_offer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Offer not found'; END IF;
  IF v_offer.status != 'pending' THEN RAISE EXCEPTION 'Offer already %', v_offer.status; END IF;
  IF v_offer.expires_at < now() THEN
    UPDATE offers SET status = 'expired' WHERE id = p_offer_id;
    RAISE EXCEPTION 'Offer expired';
  END IF;

  -- FIX 2: Atomic booking claim — only succeeds if still unassigned
  UPDATE bookings SET
    status           = 'CONFIRMED',
    fixer_id         = p_fixer_id,
    confirmed_at     = now(),
    current_offer_id = p_offer_id,
    updated_at       = now(),
    version          = version + 1
  WHERE id = v_offer.booking_id
    AND fixer_id IS NULL       -- key guard
    AND status IN ('OFFERED','SEARCHING');

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    -- Another fixer beat us
    UPDATE offers SET status = 'expired', responded_at = now() WHERE id = p_offer_id;
    RAISE EXCEPTION 'Job already taken by another fixer';
  END IF;

  SELECT * INTO v_booking FROM bookings WHERE id = v_offer.booking_id;

  UPDATE offers SET status = 'accepted', responded_at = now() WHERE id = p_offer_id;

  PERFORM mark_fixer_busy(p_fixer_id);

  -- Record response time
  SELECT notified_at INTO v_dispatch_time
  FROM dispatch_log
  WHERE booking_id = v_offer.booking_id AND fixer_id = p_fixer_id
  ORDER BY created_at DESC LIMIT 1;

  IF v_dispatch_time IS NOT NULL THEN
    v_response_secs := EXTRACT(EPOCH FROM (now() - v_dispatch_time))::INTEGER;

    UPDATE dispatch_log SET status = 'accepted', responded_at = now()
    WHERE booking_id = v_offer.booking_id AND fixer_id = p_fixer_id AND status = 'notified';

    -- FIX 5: Update response time (rolling average, last 20 jobs)
    UPDATE fixers SET
      avg_response_time = (
        SELECT ROUND(AVG(d.responded_at - d.notified_at)::NUMERIC)
        FROM (
          SELECT responded_at, notified_at
          FROM dispatch_log
          WHERE fixer_id = p_fixer_id AND status = 'accepted' AND responded_at IS NOT NULL
          ORDER BY created_at DESC LIMIT 20
        ) d
      ),
      updated_at = now()
    WHERE id = p_fixer_id;
  END IF;

  -- Expire other offers
  FOR v_losing_fixer IN
    SELECT o.id AS offer_id, f.user_id AS fixer_user_id
    FROM offers o JOIN fixers f ON f.id = o.fixer_id
    WHERE o.booking_id = v_booking.id AND o.id != p_offer_id AND o.status = 'pending'
    FOR UPDATE OF o SKIP LOCKED
  LOOP
    UPDATE offers SET status = 'expired', responded_at = now() WHERE id = v_losing_fixer.offer_id;
    INSERT INTO notifications (user_id, title, body, type, related_id)
    VALUES (v_losing_fixer.fixer_user_id, '⚡ Job taken',
      'Another fixer accepted first. Stay available!', 'offer_expired', v_booking.id);
  END LOOP;

  INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata, created_by)
  VALUES (v_booking.id, 'offer_accepted', 'OFFERED', 'CONFIRMED',
    jsonb_build_object('offer_id', p_offer_id, 'fixer_id', p_fixer_id, 'response_secs', v_response_secs),
    p_fixer_user_id);

  -- Trigger async metric + badge update
  PERFORM pg_notify('update_metrics', p_fixer_id::TEXT);

  RETURN jsonb_build_object(
    'success', true, 'booking_id', v_booking.id,
    'status', 'CONFIRMED', 'fixer_id', p_fixer_id, 'response_secs', v_response_secs
  );
END;
$$;

-- ── FIX 5: Behavioral penalties ───────────────────────────────

-- Ignore penalty: called when dispatch times out for a notified fixer
CREATE OR REPLACE FUNCTION apply_ignore_penalty(p_fixer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE fixers SET
    ignore_count    = ignore_count + 1,
    -- Acceptance rate decays: each ignore costs ~2 percentage points
    acceptance_rate = GREATEST(0, acceptance_rate - 2),
    -- Cancel penalty accumulates (caps at 0.5 = 50% score reduction)
    cancel_penalty  = LEAST(0.5, cancel_penalty + 0.02),
    updated_at      = now()
  WHERE id = p_fixer_id;
END;
$$;

-- Cancel penalty: called when fixer cancels an accepted job
CREATE OR REPLACE FUNCTION apply_cancel_penalty(p_fixer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE fixers SET
    total_cancelled = total_cancelled + 1,
    -- Heavy cancel penalty: -10 acceptance rate points + 0.15 score penalty
    acceptance_rate = GREATEST(0, acceptance_rate - 10),
    cancel_penalty  = LEAST(0.5, cancel_penalty + 0.15),
    completion_rate = CASE WHEN total_accepted > 0
      THEN GREATEST(0, (total_completed::NUMERIC / total_accepted) * 100)
      ELSE 0 END,
    updated_at      = now()
  WHERE id = p_fixer_id;

  -- Recalculate badges after penalty
  PERFORM assign_fixer_badges(p_fixer_id);
END;
$$;

-- Penalty recovery: good behavior slowly restores score
CREATE OR REPLACE FUNCTION apply_completion_reward(p_fixer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE fixers SET
    -- Each completion recovers 0.02 cancel penalty (takes ~7 jobs to recover from one cancel)
    cancel_penalty  = GREATEST(0, cancel_penalty - 0.02),
    ignore_count    = GREATEST(0, ignore_count - 1),  -- decay ignores on good behavior
    updated_at      = now()
  WHERE id = p_fixer_id;
END;
$$;

-- Wire ignore penalty into advance_expired_dispatches
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
  v_fixer_id  UUID;
BEGIN
  FOR v_booking IN
    SELECT b.id, b.service_tier, b.dispatch_sequence, b.dispatch_fixer_id, b.priority_flag
    FROM bookings b
    WHERE b.status = 'OFFERED'
      AND b.dispatch_expiry < now()
      AND b.dispatch_mode != 'manual'
    FOR UPDATE SKIP LOCKED
  LOOP
    -- FIX 5: penalise the fixer who just ignored this
    IF v_booking.dispatch_fixer_id IS NOT NULL THEN
      PERFORM apply_ignore_penalty(v_booking.dispatch_fixer_id);
    END IF;

    UPDATE dispatch_log SET status = 'timed_out', responded_at = now()
    WHERE booking_id = v_booking.id AND status = 'notified'
      AND sequence_position = v_booking.dispatch_sequence;

    UPDATE offers SET status = 'expired', responded_at = now()
    WHERE booking_id = v_booking.id AND status = 'pending';

    v_result := dispatch_next_fixer(v_booking.id);

    IF (v_result->>'action') = 'fallback' THEN
      UPDATE bookings SET
        status            = 'SEARCHING',
        dispatch_sequence = 0,
        dispatch_pass     = 1,
        dispatch_fixer_id = NULL,
        updated_at        = now(),
        version           = version + 1
      WHERE id = v_booking.id;

      INSERT INTO notifications (user_id, title, body, type, related_id)
      SELECT p.id,
        '🚨 Job unmatched — manual assignment needed',
        'All dispatch passes exhausted for booking ' || LEFT(v_booking.id::TEXT,8) ||
        '. Reason: ' || COALESCE(v_result->>'reason', 'unknown'),
        'admin_alert', v_booking.id
      FROM profiles p WHERE p.user_role = 'admin';
    END IF;

    v_advanced := v_advanced + 1;
  END LOOP;

  RETURN v_advanced;
END;
$$;

-- Wire completion reward into trigger
CREATE OR REPLACE FUNCTION trigger_update_fixer_metrics()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.fixer_id IS NULL THEN RETURN NEW; END IF;

  IF NEW.status IN ('COMPLETED','CANCELLED') AND OLD.status NOT IN ('COMPLETED','CANCELLED') THEN
    PERFORM update_fixer_metrics(NEW.fixer_id);

    IF NEW.status = 'COMPLETED' THEN
      -- FIX 5: reward good completion
      PERFORM apply_completion_reward(NEW.fixer_id);
    END IF;

    IF NEW.status = 'CANCELLED' THEN
      -- Check if fixer cancelled (not customer)
      IF EXISTS (
        SELECT 1 FROM booking_events
        WHERE booking_id = NEW.id AND event_type = 'fixer_cancelled'
      ) THEN
        PERFORM apply_cancel_penalty(NEW.fixer_id);
      END IF;
    END IF;

    PERFORM assign_fixer_badges(NEW.fixer_id);
  END IF;

  RETURN NEW;
END;
$$;

-- ── FIX 6: Dynamic badges vs system median ────────────────────
CREATE OR REPLACE FUNCTION assign_fixer_badges(p_fixer_id UUID DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count          INTEGER := 0;
  v_median_resp    NUMERIC;
  v_median_comp    NUMERIC;
  v_p75_jobs       INTEGER;
BEGIN
  -- FIX 6: compute live system medians from approved fixers
  SELECT
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_response_time),
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY completion_rate),
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY total_completed)
  INTO v_median_resp, v_median_comp, v_p75_jobs
  FROM fixers
  WHERE status = 'approved' AND total_accepted >= 3;

  -- Fallback if not enough data
  v_median_resp := COALESCE(v_median_resp, 60);
  v_median_comp := COALESCE(v_median_comp, 85);
  v_p75_jobs    := COALESCE(v_p75_jobs, 10);

  UPDATE fixers SET
    -- FIX 6: Fast Responder = better than system median response time
    badge_fast_responder = (
      avg_response_time IS NOT NULL
      AND avg_response_time < v_median_resp
      AND total_accepted >= 5
    ),
    -- FIX 6: Top Fixer = above median completion + high rating + above p75 jobs
    badge_top_fixer = (
      COALESCE(completion_rate, 0) >= GREATEST(v_median_comp, 85.0)
      AND COALESCE(rating, 0) >= 4.5
      AND total_completed >= v_p75_jobs
    ),
    badges_updated_at = now()
  WHERE (p_fixer_id IS NULL OR id = p_fixer_id)
    AND status = 'approved';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- ── FIX 7: Early warning check (runs every 2 minutes via cron) ─
-- Already wired inside dispatch_next_fixer above.
-- This function handles the broader sweep:
CREATE OR REPLACE FUNCTION check_and_alert_stuck_jobs()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
BEGIN
  -- FIX 7: premium jobs get early warning at 90s, others at 3 min
  INSERT INTO notifications (user_id, title, body, type, related_id)
  SELECT DISTINCT ON (p.id, b.id)
    p.id,
    CASE b.service_tier
      WHEN 'premium' THEN '⚠️ Premium job delayed — assign manually?'
      ELSE '⚠️ Job needs attention'
    END,
    'Booking ' || LEFT(b.id::TEXT,8) ||
    ' (' || COALESCE(b.category,'General') || ' · ' || b.service_tier ||
    ') — attempt #' || b.dispatch_sequence ||
    ', pass ' || b.dispatch_pass ||
    ', stuck ' || ROUND(EXTRACT(EPOCH FROM (now()-b.updated_at))/60) || ' min.',
    'admin_alert',
    b.id
  FROM bookings b
  CROSS JOIN profiles p
  WHERE p.user_role = 'admin'
    AND b.status IN ('SEARCHING','OFFERED')
    AND (
      (b.service_tier = 'premium' AND b.updated_at < now() - interval '90 seconds')
      OR b.updated_at < now() - interval '3 minutes'
    )
    AND NOT EXISTS (
      SELECT 1 FROM notifications n
      WHERE n.user_id    = p.id
        AND n.related_id = b.id
        AND n.type       = 'admin_alert'
        AND n.created_at > now() - interval '4 minutes'
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION build_dispatch_queue(UUID, INTEGER)               TO service_role;
GRANT EXECUTE ON FUNCTION dispatch_next_fixer(UUID)                        TO service_role;
GRANT EXECUTE ON FUNCTION get_dispatch_timeout(service_tier_enum, BOOLEAN) TO service_role;
GRANT EXECUTE ON FUNCTION advance_expired_dispatches()                     TO service_role;
GRANT EXECUTE ON FUNCTION apply_ignore_penalty(UUID)                       TO service_role;
GRANT EXECUTE ON FUNCTION apply_cancel_penalty(UUID)                       TO service_role;
GRANT EXECUTE ON FUNCTION apply_completion_reward(UUID)                    TO service_role;
GRANT EXECUTE ON FUNCTION assign_fixer_badges(UUID)                        TO service_role;
GRANT EXECUTE ON FUNCTION accept_offer(UUID, UUID, UUID)                   TO authenticated;
GRANT EXECUTE ON FUNCTION check_and_alert_stuck_jobs()                     TO service_role;
