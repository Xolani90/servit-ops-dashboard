-- ═══════════════════════════════════════════════════════════════
-- SERVIT v6.3 — Final Pre-Launch Patch
-- 1. Cold-start boost (new fixer injection)
-- 2. Penalty tolerance buffer (connectivity fairness)
-- 3. Geographic radius hard filter (query efficiency)
-- 4. Dispatch cooldown (anti-fatigue)
-- 5. Price intelligence (category averages)
-- 6. Watchdog system (stuck job detection)
-- 7. Premium hard enforcement (rating + completion gate)
-- ═══════════════════════════════════════════════════════════════

-- ── Schema additions ──────────────────────────────────────────

-- FIX 2: tolerance tracking
ALTER TABLE fixers
  ADD COLUMN IF NOT EXISTS ignore_grace_remaining INTEGER NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS penalty_window_count   INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS penalty_window_start   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_dispatched_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS cooldown_until         TIMESTAMPTZ;

-- FIX 5: price intelligence table
CREATE TABLE IF NOT EXISTS category_pricing (
  category       TEXT        PRIMARY KEY,
  avg_price      NUMERIC(10,2),
  median_price   NUMERIC(10,2),
  min_price      NUMERIC(10,2),
  max_price      NUMERIC(10,2),
  sample_count   INTEGER     NOT NULL DEFAULT 0,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- FIX 6: watchdog log
CREATE TABLE IF NOT EXISTS watchdog_log (
  id           UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id   UUID        NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  checked_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  status_found TEXT        NOT NULL,
  minutes_stuck NUMERIC(8,2),
  action_taken TEXT,
  alerted_admin BOOLEAN    NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS idx_watchdog_booking ON watchdog_log(booking_id);
CREATE INDEX IF NOT EXISTS idx_fixers_cooldown  ON fixers(cooldown_until) WHERE cooldown_until IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_fixers_dispatched ON fixers(last_dispatched_at);

-- ═══════════════════════════════════════════════════════════════
-- FIX 1: New-fixer cold-start boost
-- Fixers with < 5 completed jobs get a score injection and are
-- guaranteed inclusion in early dispatch rounds (not just scored in)
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_new_fixer_boost(
  p_jobs_completed INTEGER,
  p_pass           INTEGER DEFAULT 1
)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    -- Pass 1: meaningful boost so they appear above mediocre veterans
    WHEN p_jobs_completed = 0 THEN 0.18   -- brand new: biggest boost
    WHEN p_jobs_completed <= 2 THEN 0.12  -- 1–2 jobs: solid boost
    WHEN p_jobs_completed <= 5 THEN 0.06  -- 3–5 jobs: gentle boost
    ELSE 0.0                              -- 5+ jobs: compete on merit
  END
  -- Reduce boost on later passes (they had their chance)
  * CASE WHEN p_pass = 1 THEN 1.0 WHEN p_pass = 2 THEN 0.5 ELSE 0.0 END
$$;

-- ═══════════════════════════════════════════════════════════════
-- FIX 3+4+7: Rebuilt build_dispatch_queue with:
--   - Hard radius filter (not just soft scoring)
--   - Cooldown exclusion
--   - Cold-start boost injected into score
--   - Premium hard gate (rating ≥ 4.2, completion ≥ 85%)
-- ═══════════════════════════════════════════════════════════════

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
  v_booking    bookings%ROWTYPE;
  v_tier       service_tier_enum;
  v_lat        DOUBLE PRECISION;
  v_lng        DOUBLE PRECISION;
  v_city       TEXT;
  v_max_price  NUMERIC;
  v_min_price  NUMERIC;
  v_max_resp   NUMERIC := 300.0;
  -- FIX 3: tier-based hard radius (km)
  v_radius_km  NUMERIC;
BEGIN
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN RETURN; END IF;

  v_tier := COALESCE(v_booking.service_tier, 'standard');
  v_lat  := v_booking.customer_latitude;
  v_lng  := v_booking.customer_longitude;
  SELECT p.city INTO v_city FROM profiles p WHERE p.id = v_booking.customer_id;

  -- FIX 3: Hard radius per tier (tighter for premium — quality over quantity)
  -- Pass 2+ loosens radius by 50% to find more candidates
  CASE v_tier
    WHEN 'basic'   THEN v_radius_km := CASE WHEN p_pass = 1 THEN 30.0 ELSE 50.0 END;
    WHEN 'premium' THEN v_radius_km := CASE WHEN p_pass = 1 THEN 15.0
                                            WHEN p_pass = 2 THEN 20.0
                                            ELSE 30.0 END;
    ELSE                v_radius_km := CASE WHEN p_pass = 1 THEN 20.0 ELSE 35.0 END;
  END CASE;

  -- Normalization bounds from live pool within radius
  SELECT
    COALESCE(MAX(f.price), 1000),
    COALESCE(MIN(f.price), 0)
  INTO v_max_price, v_min_price
  FROM fixers f
  WHERE f.status = 'approved' AND f.fixer_status = 'online'
    AND (
      v_lat IS NULL OR f.latitude IS NULL OR (
        2*6371*asin(sqrt(
          power(sin(radians((f.latitude-v_lat)/2)),2)+
          cos(radians(v_lat))*cos(radians(f.latitude))*
          power(sin(radians((f.longitude-v_lng)/2)),2)
        )) <= v_radius_km
      )
    );

  IF v_max_price = v_min_price THEN v_max_price := v_min_price + 1; END IF;

  -- ── BASIC ─────────────────────────────────────────────────
  IF v_tier = 'basic' THEN
    RETURN QUERY
    WITH candidates AS (
      SELECT
        f.*,
        -- Distance in km (NULL if no geo)
        CASE WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL
          THEN 2*6371*asin(sqrt(
            power(sin(radians((f.latitude-v_lat)/2)),2)+
            cos(radians(v_lat))*cos(radians(f.latitude))*
            power(sin(radians((f.longitude-v_lng)/2)),2)))
          ELSE NULL END AS dist_km,
        CASE WHEN v_max_price > v_min_price
          THEN (v_max_price - COALESCE(f.price, v_max_price)) / (v_max_price - v_min_price)
          ELSE 0.5 END AS norm_price,
        GREATEST(0, 1.0 - CASE
          WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL
          THEN 2*6371*asin(sqrt(
            power(sin(radians((f.latitude-v_lat)/2)),2)+
            cos(radians(v_lat))*cos(radians(f.latitude))*
            power(sin(radians((f.longitude-v_lng)/2)),2)))
          ELSE v_radius_km/2 END / v_radius_km) AS norm_dist,
        -- FIX 1: cold-start boost
        get_new_fixer_boost(COALESCE(f.total_completed, f.jobs_completed, 0), p_pass) AS boost,
        GREATEST(0.5, 1.0 - COALESCE(f.cancel_penalty, 0)) AS penalty_mult
      FROM fixers f
      WHERE f.status       = 'approved'
        AND f.fixer_status  = 'online'
        AND f.last_seen_at >= now() - interval '5 minutes'
        -- FIX 4: exclude fixers in cooldown
        AND (f.cooldown_until IS NULL OR f.cooldown_until < now())
        -- FIX 3: hard radius filter (only when geo available)
        AND (
          v_lat IS NULL OR f.latitude IS NULL
          OR 2*6371*asin(sqrt(
               power(sin(radians((f.latitude-v_lat)/2)),2)+
               cos(radians(v_lat))*cos(radians(f.latitude))*
               power(sin(radians((f.longitude-v_lng)/2)),2)
             )) <= v_radius_km
          OR f.city = v_city  -- city-text fallback when no geo
        )
        AND (
          v_booking.category IS NULL
          OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
          OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id=f.id AND fc.category=v_booking.category)
        )
        AND NOT EXISTS (
          SELECT 1 FROM dispatch_log dl
          WHERE dl.booking_id = p_booking_id AND dl.fixer_id = f.id
        )
        AND (p_pass >= 2 OR COALESCE(f.acceptance_rate, 100) >= 40)
    )
    SELECT c.id,
      ROW_NUMBER() OVER (ORDER BY
        (c.norm_price * 0.55 + c.norm_dist * 0.35 + COALESCE(c.rating,3)/5.0 * 0.10)
        * c.penalty_mult + c.boost DESC
      )::INTEGER,
      (c.norm_price * 0.55 + c.norm_dist * 0.35 + COALESCE(c.rating,3)/5.0 * 0.10)
      * c.penalty_mult + c.boost AS score
    FROM candidates c
    LIMIT CASE WHEN p_pass = 1 THEN 4 ELSE 6 END;

  -- ── STANDARD ──────────────────────────────────────────────
  ELSIF v_tier = 'standard' THEN
    RETURN QUERY
    WITH candidates AS (
      SELECT
        f.*,
        CASE WHEN v_max_price > v_min_price
          THEN (v_max_price - COALESCE(f.price, v_max_price)) / (v_max_price - v_min_price)
          ELSE 0.5 END AS norm_price,
        GREATEST(0, 1.0 - CASE
          WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL
          THEN 2*6371*asin(sqrt(
            power(sin(radians((f.latitude-v_lat)/2)),2)+
            cos(radians(v_lat))*cos(radians(f.latitude))*
            power(sin(radians((f.longitude-v_lng)/2)),2)))
          ELSE v_radius_km/2 END / v_radius_km) AS norm_dist,
        COALESCE(f.rating, 3.5) / 5.0 AS norm_rating,
        COALESCE(f.acceptance_rate, 80) / 100.0 AS norm_acc,
        GREATEST(0, 1.0 - COALESCE(f.avg_response_time, 90)::NUMERIC / v_max_resp) AS norm_resp,
        get_new_fixer_boost(COALESCE(f.total_completed, f.jobs_completed, 0), p_pass) AS boost,
        GREATEST(0.5, 1.0 - COALESCE(f.cancel_penalty, 0)) AS penalty_mult
      FROM fixers f
      WHERE f.status       = 'approved'
        AND f.fixer_status  = 'online'
        AND f.last_seen_at >= now() - interval '4 minutes'
        AND (f.cooldown_until IS NULL OR f.cooldown_until < now())
        AND (
          v_lat IS NULL OR f.latitude IS NULL
          OR 2*6371*asin(sqrt(
               power(sin(radians((f.latitude-v_lat)/2)),2)+
               cos(radians(v_lat))*cos(radians(f.latitude))*
               power(sin(radians((f.longitude-v_lng)/2)),2)
             )) <= v_radius_km
          OR f.city = v_city
        )
        AND (
          v_booking.category IS NULL
          OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
          OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id=f.id AND fc.category=v_booking.category)
        )
        AND NOT EXISTS (
          SELECT 1 FROM dispatch_log dl
          WHERE dl.booking_id = p_booking_id AND dl.fixer_id = f.id
        )
        AND (p_pass >= 2 OR COALESCE(f.acceptance_rate, 100) >= 50)
    )
    SELECT c.id,
      ROW_NUMBER() OVER (ORDER BY
        (c.norm_rating * 0.35 + c.norm_dist * 0.30 + c.norm_acc * 0.20 + c.norm_resp * 0.15)
        * c.penalty_mult + c.boost DESC
      )::INTEGER,
      (c.norm_rating * 0.35 + c.norm_dist * 0.30 + c.norm_acc * 0.20 + c.norm_resp * 0.15)
      * c.penalty_mult + c.boost AS score
    FROM candidates c
    LIMIT CASE WHEN p_pass = 1 THEN 4 ELSE 6 END;

  -- ── PREMIUM ───────────────────────────────────────────────
  ELSE
    RETURN QUERY
    WITH candidates AS (
      SELECT
        f.*,
        COALESCE(f.rating, 3.0) / 5.0 AS norm_rating,
        GREATEST(0, 1.0 - COALESCE(f.avg_response_time, 60)::NUMERIC / v_max_resp) AS norm_resp,
        COALESCE(f.completion_rate, 80) / 100.0 AS norm_comp,
        GREATEST(0, 1.0 - CASE
          WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL
          THEN 2*6371*asin(sqrt(
            power(sin(radians((f.latitude-v_lat)/2)),2)+
            cos(radians(v_lat))*cos(radians(f.latitude))*
            power(sin(radians((f.longitude-v_lng)/2)),2)))
          ELSE v_radius_km/2 END / v_radius_km) AS norm_dist,
        get_new_fixer_boost(COALESCE(f.total_completed, f.jobs_completed, 0), p_pass) AS boost,
        -- FIX 7+v6.2: heavier cancel penalty for premium
        GREATEST(0.3, 1.0 - COALESCE(f.cancel_penalty, 0) * 1.5) AS penalty_mult
      FROM fixers f
      WHERE f.status       = 'approved'
        AND f.fixer_status  = 'online'
        AND f.last_seen_at >= now() - interval '3 minutes'
        AND (f.cooldown_until IS NULL OR f.cooldown_until < now())
        AND (
          v_lat IS NULL OR f.latitude IS NULL
          OR 2*6371*asin(sqrt(
               power(sin(radians((f.latitude-v_lat)/2)),2)+
               cos(radians(v_lat))*cos(radians(f.latitude))*
               power(sin(radians((f.longitude-v_lng)/2)),2)
             )) <= v_radius_km
          OR f.city = v_city
        )
        AND (
          v_booking.category IS NULL
          OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
          OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id=f.id AND fc.category=v_booking.category)
        )
        AND NOT EXISTS (
          SELECT 1 FROM dispatch_log dl
          WHERE dl.booking_id = p_booking_id AND dl.fixer_id = f.id
        )
        -- FIX 7: HARD gate per pass — not just scoring, hard exclusion
        AND CASE
          WHEN p_pass = 1 THEN
            f.is_verified = true
            AND COALESCE(f.rating, 0)          >= 4.5
            AND COALESCE(f.completion_rate, 0) >= 90
          WHEN p_pass = 2 THEN
            f.is_verified = true
            AND COALESCE(f.rating, 0)          >= 4.2   -- FIX 7: enforced minimum
            AND COALESCE(f.completion_rate, 0) >= 85    -- FIX 7: enforced minimum
          WHEN p_pass = 3 THEN
            -- Opens to unverified but still holds quality floor
            COALESCE(f.rating, 0)          >= 4.2
            AND COALESCE(f.completion_rate, 0) >= 85
          ELSE
            -- Pass 4: absolute floor — still premium, cannot go below this
            COALESCE(f.rating, 0)          >= 4.0
            AND COALESCE(f.completion_rate, 0) >= 80
        END
        -- FIX 1: New fixers exempt from pass 3+ hard gates if very new
        OR (
          COALESCE(f.total_completed, 0) = 0
          AND f.is_verified = true  -- new but verified = admin-approved
          AND p_pass >= 3
        )
    )
    SELECT c.id,
      ROW_NUMBER() OVER (ORDER BY
        (c.norm_rating * 0.45 + c.norm_resp * 0.30 + c.norm_comp * 0.15 + c.norm_dist * 0.10)
        * c.penalty_mult + c.boost DESC
      )::INTEGER,
      (c.norm_rating * 0.45 + c.norm_resp * 0.30 + c.norm_comp * 0.15 + c.norm_dist * 0.10)
      * c.penalty_mult + c.boost AS score
    FROM candidates c
    LIMIT CASE WHEN p_pass = 1 THEN 3 WHEN p_pass = 2 THEN 4 ELSE 5 END;
  END IF;
END;
$$;

-- ═══════════════════════════════════════════════════════════════
-- FIX 2: Tolerance-aware ignore penalty
-- Respects connectivity issues — first 3 ignores are grace period
-- Caps at 3 penalties per 24-hour window to prevent pile-on
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION apply_ignore_penalty(p_fixer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fixer fixers%ROWTYPE;
BEGIN
  SELECT * INTO v_fixer FROM fixers WHERE id = p_fixer_id FOR UPDATE;

  -- FIX 2: grace period — first 3 ignores cost nothing
  IF v_fixer.ignore_grace_remaining > 0 THEN
    UPDATE fixers SET
      ignore_grace_remaining = ignore_grace_remaining - 1,
      last_dispatched_at     = now()
    WHERE id = p_fixer_id;
    RETURN;
  END IF;

  -- FIX 2: reset penalty window if > 24 hours since window started
  IF v_fixer.penalty_window_start IS NULL
     OR v_fixer.penalty_window_start < now() - interval '24 hours' THEN
    UPDATE fixers SET
      penalty_window_count = 0,
      penalty_window_start = now()
    WHERE id = p_fixer_id;
    v_fixer.penalty_window_count := 0;
  END IF;

  -- FIX 2: cap at 3 penalty events per 24-hour window
  IF v_fixer.penalty_window_count >= 3 THEN
    -- Already hit cap today — apply cooldown only, no further metric damage
    UPDATE fixers SET
      cooldown_until     = now() + interval '2 minutes',
      last_dispatched_at = now()
    WHERE id = p_fixer_id;
    RETURN;
  END IF;

  -- Apply penalty + cooldown
  UPDATE fixers SET
    ignore_count          = ignore_count + 1,
    acceptance_rate       = GREATEST(0, acceptance_rate - 2),
    cancel_penalty        = LEAST(0.5, cancel_penalty + 0.02),
    -- FIX 4: cooldown after ignore (3 min, 5 min if chronic)
    cooldown_until        = now() + CASE
                              WHEN ignore_count >= 5 THEN interval '5 minutes'
                              ELSE                        interval '3 minutes'
                            END,
    penalty_window_count  = penalty_window_count + 1,
    penalty_window_start  = COALESCE(penalty_window_start, now()),
    last_dispatched_at    = now()
  WHERE id = p_fixer_id;
END;
$$;

-- FIX 4: Cooldown after voluntary decline
CREATE OR REPLACE FUNCTION apply_decline_cooldown(p_fixer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Declines are softer than ignores — shorter cooldown, no metric hit
  UPDATE fixers SET
    cooldown_until     = now() + interval '2 minutes',
    last_dispatched_at = now()
  WHERE id = p_fixer_id;
END;
$$;

-- FIX 4: Wire decline cooldown into decline_offer
CREATE OR REPLACE FUNCTION decline_offer(p_offer_id UUID, p_fixer_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offer    offers%ROWTYPE;
  v_fixer_id UUID;
BEGIN
  SELECT id INTO v_fixer_id FROM fixers WHERE user_id = p_fixer_user_id;

  SELECT * INTO v_offer FROM offers WHERE id = p_offer_id AND fixer_id = v_fixer_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Offer not found'; END IF;
  IF v_offer.status != 'pending' THEN RAISE EXCEPTION 'Offer already %', v_offer.status; END IF;

  UPDATE offers SET status = 'declined', responded_at = now() WHERE id = p_offer_id;

  UPDATE dispatch_log SET status = 'timed_out', responded_at = now()
  WHERE booking_id = v_offer.booking_id AND fixer_id = v_fixer_id AND status = 'notified';

  -- FIX 4: cooldown (no metric damage for honest decline)
  PERFORM apply_decline_cooldown(v_fixer_id);

  -- Accept rate slight hit for decline (less than ignore)
  UPDATE fixers SET
    acceptance_rate = GREATEST(0, acceptance_rate - 1)
  WHERE id = v_fixer_id;

  -- Advance dispatch to next fixer
  PERFORM dispatch_next_fixer(v_offer.booking_id);

  RETURN jsonb_build_object('success', true, 'offer_id', p_offer_id);
END;
$$;

-- Restore grace on good behavior (completion)
CREATE OR REPLACE FUNCTION apply_completion_reward(p_fixer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE fixers SET
    cancel_penalty         = GREATEST(0, cancel_penalty - 0.02),
    ignore_count           = GREATEST(0, ignore_count - 1),
    -- FIX 2: restore 1 grace credit per completion (max 3)
    ignore_grace_remaining = LEAST(3, ignore_grace_remaining + 1),
    -- Decay penalty window count on good behavior
    penalty_window_count   = GREATEST(0, penalty_window_count - 1),
    updated_at             = now()
  WHERE id = p_fixer_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════
-- FIX 5: Price intelligence
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION refresh_category_pricing()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
BEGIN
  INSERT INTO category_pricing (category, avg_price, median_price, min_price, max_price, sample_count, updated_at)
  SELECT
    b.category,
    ROUND(AVG(b.customer_total), 2),
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY b.customer_total), 2),
    ROUND(MIN(b.customer_total), 2),
    ROUND(MAX(b.customer_total), 2),
    COUNT(*)::INTEGER,
    now()
  FROM bookings b
  WHERE b.status      = 'COMPLETED'
    AND b.category    IS NOT NULL
    AND b.customer_total > 0
    AND b.created_at  > now() - interval '90 days'  -- rolling 90-day window
  GROUP BY b.category
  HAVING COUNT(*) >= 3  -- minimum sample size for reliability
  ON CONFLICT (category) DO UPDATE SET
    avg_price    = EXCLUDED.avg_price,
    median_price = EXCLUDED.median_price,
    min_price    = EXCLUDED.min_price,
    max_price    = EXCLUDED.max_price,
    sample_count = EXCLUDED.sample_count,
    updated_at   = now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- API: return price guidance for a category
CREATE OR REPLACE FUNCTION get_price_guidance(p_category TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pricing category_pricing%ROWTYPE;
BEGIN
  SELECT * INTO v_pricing FROM category_pricing WHERE category = p_category;

  IF NOT FOUND THEN
    -- No data yet — return generic guidance
    RETURN jsonb_build_object(
      'has_data',   false,
      'category',   p_category,
      'suggestion', 'Enter your budget. Most jobs in this category are priced between R150–R800.'
    );
  END IF;

  RETURN jsonb_build_object(
    'has_data',     true,
    'category',     p_category,
    'avg_price',    v_pricing.avg_price,
    'median_price', v_pricing.median_price,
    'min_price',    v_pricing.min_price,
    'max_price',    v_pricing.max_price,
    'sample_count', v_pricing.sample_count,
    'suggestion',   'Most ' || p_category || ' jobs are priced between R' ||
                    ROUND(v_pricing.min_price) || ' and R' ||
                    ROUND(v_pricing.max_price) || '. Average: R' ||
                    ROUND(v_pricing.avg_price) || '.',
    'updated_at',   v_pricing.updated_at
  );
END;
$$;

-- ═══════════════════════════════════════════════════════════════
-- FIX 6: Watchdog — detects and escalates stuck jobs
-- Covers: SEARCHING, OFFERED, CONFIRMED, IN_PROGRESS
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION run_watchdog()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking    RECORD;
  v_action     TEXT;
  v_alerted    BOOLEAN;
  v_minutes    NUMERIC;
  v_count      INTEGER := 0;
BEGIN
  FOR v_booking IN
    SELECT
      b.id, b.status, b.service_tier, b.category, b.fixer_id,
      b.dispatch_sequence, b.dispatch_pass, b.priority_flag,
      ROUND(EXTRACT(EPOCH FROM (now() - b.updated_at))/60, 1) AS minutes_stuck
    FROM bookings b
    WHERE b.status IN ('SEARCHING','OFFERED','CONFIRMED','IN_PROGRESS')
      AND (
        -- SEARCHING/OFFERED: alert after 5 min (premium: 2 min)
        (b.status IN ('SEARCHING','OFFERED') AND (
          (b.service_tier = 'premium' AND b.updated_at < now() - interval '2 minutes')
          OR b.updated_at < now() - interval '5 minutes'
        ))
        -- CONFIRMED: fixer hasn't moved after 20 min
        OR (b.status = 'CONFIRMED' AND b.updated_at < now() - interval '20 minutes')
        -- IN_PROGRESS: job taking longer than 4 hours
        OR (b.status = 'IN_PROGRESS' AND b.updated_at < now() - interval '4 hours')
      )
      -- Don't re-log if already logged in last 10 min
      AND NOT EXISTS (
        SELECT 1 FROM watchdog_log wl
        WHERE wl.booking_id  = b.id
          AND wl.checked_at > now() - interval '10 minutes'
      )
  LOOP
    v_minutes := v_booking.minutes_stuck;
    v_alerted := false;

    CASE v_booking.status
      WHEN 'SEARCHING', 'OFFERED' THEN
        v_action := 'dispatch_stalled';
        -- Auto-retry dispatch if still in early stages
        IF v_booking.dispatch_sequence <= 1 AND v_booking.status = 'OFFERED' THEN
          PERFORM dispatch_next_fixer(v_booking.id);
          v_action := 'auto_redispatched';
        END IF;

      WHEN 'CONFIRMED' THEN
        -- Fixer assigned but hasn't started — nudge them
        v_action := 'fixer_not_started';
        INSERT INTO notifications (user_id, title, body, type, related_id)
        SELECT f.user_id,
          '⏰ Reminder: job not started',
          'Your assigned job has not been marked as started yet. Please update the status.',
          'reminder', v_booking.id
        FROM fixers f WHERE f.id = v_booking.fixer_id;

      WHEN 'IN_PROGRESS' THEN
        v_action := 'job_overrunning';
    END CASE;

    -- Alert admin for all stuck cases
    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT p.id,
      '🔍 Watchdog: ' || v_booking.status || ' job stuck',
      'Booking ' || LEFT(v_booking.id::TEXT, 8) ||
      ' (' || COALESCE(v_booking.category,'General') || ' · ' || v_booking.service_tier || ')' ||
      ' stuck for ' || v_minutes || ' min — action: ' || v_action,
      'admin_watchdog',
      v_booking.id
    FROM profiles p
    WHERE p.user_role = 'admin'
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.user_id    = p.id
          AND n.related_id = v_booking.id
          AND n.type       = 'admin_watchdog'
          AND n.created_at > now() - interval '10 minutes'
      );

    v_alerted := true;

    INSERT INTO watchdog_log (booking_id, status_found, minutes_stuck, action_taken, alerted_admin)
    VALUES (v_booking.id, v_booking.status, v_minutes, v_action, v_alerted);

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- ═══════════════════════════════════════════════════════════════
-- FIX 5: Frontend endpoint — price guidance
-- ═══════════════════════════════════════════════════════════════

-- RLS: category_pricing is public read
ALTER TABLE category_pricing ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS category_pricing_public_read ON category_pricing;
CREATE POLICY category_pricing_public_read ON category_pricing
  FOR SELECT USING (true);

-- Watchdog log: admin only
ALTER TABLE watchdog_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS watchdog_log_admin_only ON watchdog_log;
CREATE POLICY watchdog_log_admin_only ON watchdog_log
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND user_role = 'admin')
  );

-- ── Cron schedules ────────────────────────────────────────────
-- Add these in Supabase Dashboard → Database → Cron Jobs:
-- SELECT cron.schedule('watchdog',             '5 minutes',  $$SELECT run_watchdog()$$);
-- SELECT cron.schedule('refresh-pricing',      '6 hours',    $$SELECT refresh_category_pricing()$$);

-- ── Grants ───────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION build_dispatch_queue(UUID, INTEGER)     TO service_role;
GRANT EXECUTE ON FUNCTION get_new_fixer_boost(INTEGER, INTEGER)   TO service_role;
GRANT EXECUTE ON FUNCTION apply_ignore_penalty(UUID)              TO service_role;
GRANT EXECUTE ON FUNCTION apply_decline_cooldown(UUID)            TO service_role;
GRANT EXECUTE ON FUNCTION apply_completion_reward(UUID)           TO service_role;
GRANT EXECUTE ON FUNCTION decline_offer(UUID, UUID)               TO authenticated;
GRANT EXECUTE ON FUNCTION refresh_category_pricing()              TO service_role;
GRANT EXECUTE ON FUNCTION get_price_guidance(TEXT)                TO authenticated, anon;
GRANT EXECUTE ON FUNCTION run_watchdog()                          TO service_role;
GRANT SELECT ON category_pricing                                  TO authenticated, anon;
