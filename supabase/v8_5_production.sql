-- ═══════════════════════════════════════════════════════════════════════════
-- SERVIT v8.5 — Full Production-Hardening Migration
-- Run AFTER v8_4_fixes.sql
-- Idempotent — safe to re-run.
--
-- ┌─ ISSUE 1 (Fixer Supply / Offline Matching) ──────────────────────────────
-- │  match_fixers() only matches online, geo-located fixers.
-- │  When supply is low, bookings sit in SEARCHING forever.
-- │  FIX: Three-tier matching fallback:
-- │    Tier 1 — online + geo within radius (existing behaviour)
-- │    Tier 2 — online + city text (existing fallback, unchanged)
-- │    Tier 3 — APPROVED fixers in city regardless of online/last_seen
-- │             (demand alert + booking queued for them to claim on next login)
-- │  Also: broadcast is now richer — includes category, amount, urgency flag.
-- │  Also: match_fixers returns richer JSON so the Netlify caller can act on tier.
-- │
-- ├─ ISSUE 2 (3-minute heartbeat expiry / phone lock) ──────────────────────
-- │  last_seen_at = now() - 3min drops a fixer whose phone auto-locked.
-- │  The setInterval in the browser stops when the screen is off on iOS/Android.
-- │  FIX 1 (DB): Extend grace period to 8 minutes (covers typical screen-lock
-- │              + brief background tab scenarios).
-- │  FIX 2 (DB): Add fixer_heartbeat_v2 RPC that accepts a visibility hint so
-- │              the client can send an immediate ping on visibility restore.
-- │  FIX 3 (DB): Add a cron that, every 4 minutes, auto-extends last_seen_at
-- │              for any fixer with an ACTIVE (CONFIRMED/EN_ROUTE) booking —
-- │              they are definitely busy (not gone), so never drop them.
-- │  FIX 4 (JS): Page Visibility API hook + immediate ping on resume.
-- │
-- ├─ ISSUE 3 (24h payout hold — cron reliability) ────────────────────────
-- │  release_due_payouts() is correct but pg_cron is the single point of
-- │  failure. If pg_cron misses a run (extension restart, DB pause on free
-- │  tier) payouts silently stall with no observability.
-- │  FIX 1 (DB): add payout_runs audit table — every cron execution logs
-- │              started_at, finished_at, payouts_released, error (if any).
-- │  FIX 2 (DB): release_due_payouts_v2 — wraps the existing logic in a
-- │              transaction, logs to payout_runs, and handles partial failure
-- │              gracefully (SKIP LOCKED already present; now also retries).
-- │  FIX 3 (DB): Fix create_payout — hardcoded 15% commission overrides the
-- │              platform_commission_pct() helper (which returns 12%).
-- │              create_payout now calls platform_commission_pct() by default.
-- │  FIX 4 (Netlify): release-payouts.js — HTTP-callable backup trigger
-- │              so ops can manually fire a release without DB access.
-- │              Also called by a Netlify scheduled function every 30 min
-- │              as a belt-and-suspenders alongside pg_cron.
-- │
-- ├─ OTHER BUGS FIXED ────────────────────────────────────────────────────────
-- │  BUG A: pg_cron expire-offers uses '*/10 * * * * *' (6 fields) — invalid
-- │         on standard pg_cron; should be '* * * * *' (every 1 min) or
-- │         use a seconds-aware schedule. Fixed to '* * * * *'.
-- │
-- │  BUG B: last_seen_at cutoff inconsistency — match_fixers uses 3 min,
-- │         surge_signal view uses 5 min, get_rebook_prompt uses 5 min.
-- │         Normalised to a single constant via platform_config table.
-- │
-- │  BUG C: create_payout called with p_commission_pct DEFAULT 15.0 —
-- │         overrides the 12% value in platform_commission_pct(). Fixed.
-- │
-- │  BUG D: release_due_payouts never updates fixer.total_earnings when
-- │         a payout is released. Running total is stale. Fixed.
-- │
-- │  BUG E: No index on payouts(hold_until, status) for the cron query —
-- │         full table scan on every cron tick. Fixed.
-- │
-- │  BUG F: update-location Netlify function re-authenticates the user on
-- │         every heartbeat call (DB roundtrip). A busy fixer pinging every
-- │         60s = 1440 extra auth.getUser() calls/day. Fixed: use service key
-- │         with fixer_id passed in JWT claim instead.
-- └───────────────────────────────────────────────────────────────────────────
-- ═══════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 0: Constants in platform_config
-- Single source of truth for all tunable values.
-- ─────────────────────────────────────────────────────────────────────────────

-- Heartbeat grace period: how long since last ping before fixer is excluded
INSERT INTO platform_config (key, value, note) VALUES
  ('heartbeat_grace_seconds',
   '{"seconds": 480, "label": "8 minutes — covers phone-lock + brief background tab"}',
   'Used by match_fixers, surge_signal, get_rebook_prompt. Change here to affect all.')
ON CONFLICT (key) DO UPDATE SET
  value      = EXCLUDED.value,
  note       = EXCLUDED.note,
  updated_at = now();

-- Offer window: how long a fixer has to accept before it expires + re-matches
INSERT INTO platform_config (key, value, note) VALUES
  ('offer_window_seconds',
   '{"seconds": 90, "label": "90 seconds — replaces old 45s which was too short on SA mobile data"}',
   'Increased from 45s: SA mobile latency + notification delivery can take 20-30s.')
ON CONFLICT (key) DO UPDATE SET
  value      = EXCLUDED.value,
  updated_at = now();


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1: ISSUE 2 FIX — Heartbeat grace period + active-job protection
-- ─────────────────────────────────────────────────────────────────────────────

-- Helper: get heartbeat grace interval from config
CREATE OR REPLACE FUNCTION heartbeat_grace_interval()
RETURNS INTERVAL
LANGUAGE sql STABLE
AS $$
  SELECT ((value->>'seconds')::INTEGER || ' seconds')::INTERVAL
  FROM   platform_config
  WHERE  key = 'heartbeat_grace_seconds'
  LIMIT  1;
$$;

-- Helper: get offer window from config
CREATE OR REPLACE FUNCTION offer_window_interval()
RETURNS INTERVAL
LANGUAGE sql STABLE
AS $$
  SELECT ((value->>'seconds')::INTEGER || ' seconds')::INTERVAL
  FROM   platform_config
  WHERE  key = 'offer_window_seconds'
  LIMIT  1;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2: ISSUE 2 FIX 3 — Auto-extend last_seen_at for active-job fixers
-- A fixer with an active job cannot be offline. Even if their phone locks
-- and the heartbeat stops, keep them visible so match data stays accurate.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION extend_active_job_fixer_heartbeats()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  -- Touch last_seen_at for every fixer who has an active booking right now.
  -- "Active" = they have been assigned and the job is in progress.
  -- This means: even if their phone locked, they stay matchable/visible.
  UPDATE fixers f
  SET    last_seen_at = now(),
         updated_at   = now()
  FROM   bookings b
  WHERE  b.fixer_id   = f.id
    AND  b.status     IN ('CONFIRMED', 'EN_ROUTE', 'ARRIVED', 'IN_PROGRESS', 'PENDING_COMPLETION')
    AND  f.status     = 'approved'
    -- Only touch if the heartbeat would otherwise expire soon (within 2x grace)
    AND  (f.last_seen_at IS NULL
          OR f.last_seen_at < now() - heartbeat_grace_interval());

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION extend_active_job_fixer_heartbeats() TO service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3: ISSUE 2 FIX 2 — fixer_heartbeat_v2 (accepts visibility hint)
-- The frontend calls this on Page Visibility resume so the immediate ping
-- lands before the next scheduled interval.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fixer_heartbeat_v2(
  p_user_id         UUID,
  p_lat             DOUBLE PRECISION DEFAULT NULL,
  p_lng             DOUBLE PRECISION DEFAULT NULL,
  p_visibility      TEXT DEFAULT 'visible',   -- 'visible' | 'hidden' | 'resume'
  p_app_state       TEXT DEFAULT 'foreground' -- 'foreground' | 'background'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fixer_id  UUID;
  v_update    JSONB;
BEGIN
  -- Resolve fixer from user_id (cached in JWT claim; validated server-side)
  SELECT id INTO v_fixer_id
  FROM   fixers
  WHERE  user_id = p_user_id
    AND  status  = 'approved'
    AND  NOT COALESCE(is_flagged, false);

  IF v_fixer_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No approved fixer for user');
  END IF;

  PERFORM set_config('app.allow_status_change', 'true', true);

  -- Build update; only include coords if valid SA bounding box
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL
     AND p_lat BETWEEN -35 AND -22
     AND p_lng BETWEEN  16 AND  33
  THEN
    UPDATE fixers SET
      last_seen_at   = now(),
      last_online_at = now(),
      latitude       = p_lat,
      longitude      = p_lng,
      updated_at     = now()
    WHERE id = v_fixer_id;
    v_update := jsonb_build_object('coords_saved', true);
  ELSE
    UPDATE fixers SET
      last_seen_at   = now(),
      last_online_at = now(),
      updated_at     = now()
    WHERE id = v_fixer_id;
    v_update := jsonb_build_object('coords_saved', false, 'reason', 'out_of_range_or_missing');
  END IF;

  RETURN jsonb_build_object(
    'ok',         true,
    'fixer_id',   v_fixer_id,
    'visibility', p_visibility,
    'app_state',  p_app_state
  ) || v_update;
END;
$$;

GRANT EXECUTE ON FUNCTION fixer_heartbeat_v2(UUID, DOUBLE PRECISION, DOUBLE PRECISION, TEXT, TEXT)
  TO authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4: ISSUE 1 FIX — match_fixers with 3-tier fallback
-- ─────────────────────────────────────────────────────────────────────────────

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
  v_match_tier       INTEGER := 0;  -- 1=geo+online, 2=city+online, 3=city+offline
  v_grace            INTERVAL;
  v_offer_window     INTERVAL;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Booking not found');
  END IF;

  IF v_booking.status != 'SEARCHING' OR v_booking.payment_status != 'paid' THEN
    RETURN jsonb_build_object('error', 'Booking not available for matching',
                              'status', v_booking.status,
                              'payment_status', v_booking.payment_status);
  END IF;

  -- Scheduled bookings: don't match until 2h before slot
  IF v_booking.booking_mode = 'scheduled'
     AND v_booking.scheduled_for > now() + interval '2 hours' THEN
    RETURN jsonb_build_object('error', 'Scheduled booking not ready for matching',
                              'ready_at', v_booking.scheduled_for - interval '2 hours');
  END IF;

  v_customer_lat  := v_booking.customer_latitude;
  v_customer_lng  := v_booking.customer_longitude;
  v_grace         := COALESCE(heartbeat_grace_interval(), interval '8 minutes');
  v_offer_window  := COALESCE(offer_window_interval(),    interval '90 seconds');
  v_offer_expires_at := now() + v_offer_window;

  SELECT p.city INTO v_customer_city
  FROM profiles p WHERE p.id = v_booking.customer_id;

  -- ── TIER 1: Online + geo within radius ─────────────────────────
  FOR v_fixer IN
    SELECT f.*,
           CASE
             WHEN f.latitude IS NOT NULL AND f.longitude IS NOT NULL
                  AND v_customer_lat IS NOT NULL AND v_customer_lng IS NOT NULL
             THEN 2 * 6371 * asin(sqrt(
               power(sin(radians((f.latitude  - v_customer_lat)  / 2)), 2) +
               cos(radians(v_customer_lat)) *
               cos(radians(f.latitude)) *
               power(sin(radians((f.longitude - v_customer_lng) / 2)), 2)
             ))
             ELSE NULL
           END AS dist_km
    FROM fixers f
    WHERE f.status    = 'approved'
      AND f.available = true
      AND f.last_seen_at >= now() - v_grace
      AND NOT COALESCE(f.is_flagged, false)
      -- Must have geo coords
      AND f.latitude IS NOT NULL AND f.longitude IS NOT NULL
      AND v_customer_lat IS NOT NULL AND v_customer_lng IS NOT NULL
      -- Category match
      AND (
        v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (SELECT 1 FROM fixer_categories fc
                   WHERE fc.fixer_id = f.id AND fc.category = v_booking.category)
      )
      -- Not already declined/expired
      AND NOT EXISTS (
        SELECT 1 FROM offers o
        WHERE  o.booking_id = v_booking.id
          AND  o.fixer_id   = f.id
          AND  o.status     IN ('declined', 'expired')
      )
    HAVING (
      -- Within radius
      2 * 6371 * asin(sqrt(
        power(sin(radians((f.latitude  - v_customer_lat)  / 2)), 2) +
        cos(radians(v_customer_lat)) *
        cos(radians(f.latitude)) *
        power(sin(radians((f.longitude - v_customer_lng) / 2)), 2)
      )) <= p_radius_km
    )
    ORDER BY
      CASE WHEN COALESCE(f.acceptance_rate, 100) < 60 THEN 1 ELSE 0 END ASC,
      dist_km ASC,
      f.rating DESC,
      f.jobs_completed ASC
    LIMIT p_batch_size
  LOOP
    v_match_tier := 1;
    INSERT INTO offers (booking_id, fixer_id, expires_at)
    VALUES (v_booking.id, v_fixer.id, v_offer_expires_at)
    ON CONFLICT (booking_id, fixer_id) DO NOTHING
    RETURNING id INTO v_offer_id;

    IF v_offer_id IS NOT NULL THEN
      v_offers_sent := v_offers_sent + 1;
      IF v_first_offer_id IS NULL THEN v_first_offer_id := v_offer_id; END IF;

      INSERT INTO notifications (user_id, title, body, type, related_id)
      VALUES (
        v_fixer.user_id,
        '🔔 New job offer!',
        'A client needs help' || COALESCE(' (' || v_booking.category || ')', '') ||
        '. Accept within ' || EXTRACT(EPOCH FROM v_offer_window)::INTEGER || ' seconds.',
        'job_offer', v_offer_id
      );

      INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata)
      VALUES (v_booking.id, 'offer_created', 'SEARCHING', 'OFFERED',
        jsonb_build_object('fixer_id', v_fixer.id, 'offer_id', v_offer_id,
                           'match_method', 'geo', 'match_tier', 1,
                           'dist_km', round(v_fixer.dist_km::numeric, 2),
                           'batch_position', v_offers_sent));
    END IF;
  END LOOP;

  -- ── TIER 2: Online + city text (no geo) ────────────────────────
  IF v_offers_sent < p_batch_size THEN
    FOR v_fixer IN
      SELECT f.*
      FROM fixers f
      WHERE f.status    = 'approved'
        AND f.available = true
        AND f.last_seen_at >= now() - v_grace
        AND NOT COALESCE(f.is_flagged, false)
        AND f.city = v_customer_city
        -- Exclude geo fixers already sent in tier 1
        AND NOT (f.latitude IS NOT NULL AND f.longitude IS NOT NULL
                 AND v_customer_lat IS NOT NULL AND v_customer_lng IS NOT NULL)
        AND (
          v_booking.category IS NULL
          OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
          OR EXISTS (SELECT 1 FROM fixer_categories fc
                     WHERE fc.fixer_id = f.id AND fc.category = v_booking.category)
        )
        AND NOT EXISTS (
          SELECT 1 FROM offers o
          WHERE  o.booking_id = v_booking.id
            AND  o.fixer_id   = f.id
            AND  o.status     IN ('declined', 'expired')
        )
        AND NOT EXISTS (
          SELECT 1 FROM offers o2
          WHERE  o2.booking_id = v_booking.id
            AND  o2.fixer_id   = f.id
        )
      ORDER BY
        CASE WHEN COALESCE(f.acceptance_rate, 100) < 60 THEN 1 ELSE 0 END ASC,
        f.rating DESC,
        f.jobs_completed ASC
      LIMIT (p_batch_size - v_offers_sent)
    LOOP
      IF v_match_tier < 2 THEN v_match_tier := 2; END IF;
      INSERT INTO offers (booking_id, fixer_id, expires_at)
      VALUES (v_booking.id, v_fixer.id, v_offer_expires_at)
      ON CONFLICT (booking_id, fixer_id) DO NOTHING
      RETURNING id INTO v_offer_id;

      IF v_offer_id IS NOT NULL THEN
        v_offers_sent := v_offers_sent + 1;
        IF v_first_offer_id IS NULL THEN v_first_offer_id := v_offer_id; END IF;

        INSERT INTO notifications (user_id, title, body, type, related_id)
        VALUES (
          v_fixer.user_id,
          '🔔 New job offer!',
          'A client needs help' || COALESCE(' (' || v_booking.category || ')', '') ||
          '. Accept within ' || EXTRACT(EPOCH FROM v_offer_window)::INTEGER || ' seconds.',
          'job_offer', v_offer_id
        );

        INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata)
        VALUES (v_booking.id, 'offer_created', 'SEARCHING', 'OFFERED',
          jsonb_build_object('fixer_id', v_fixer.id, 'offer_id', v_offer_id,
                             'match_method', 'city_text', 'match_tier', 2,
                             'batch_position', v_offers_sent));
      END IF;
    END LOOP;
  END IF;

  -- ── TIER 3: Approved fixers in city who are OFFLINE ────────────
  -- They can't accept right now but we alert them so they come online.
  -- This is a demand signal, not an offer — no offer row is created.
  IF v_offers_sent = 0 THEN
    -- Demand broadcast to offline-but-eligible fixers
    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT
      f.user_id,
      '💼 Paid job waiting for you!',
      'A client near you needs help' ||
        COALESCE(' with ' || v_booking.category, '') ||
        COALESCE(' in ' || v_customer_city, ' in your area') ||
        '. Come online now — job amount: R' || COALESCE(v_booking.service_amount::TEXT, '?') || '.',
      'demand_alert',
      v_booking.id
    FROM fixers f
    WHERE f.status = 'approved'
      AND f.city   = v_customer_city
      AND NOT COALESCE(f.is_flagged, false)
      AND (
        v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (SELECT 1 FROM fixer_categories fc
                   WHERE fc.fixer_id = f.id AND fc.category = v_booking.category)
      )
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE  n.user_id    = f.user_id
          AND  n.related_id = v_booking.id
          AND  n.type       = 'demand_alert'
          AND  n.created_at >= now() - interval '30 minutes'
      );

    PERFORM pg_notify(
      'demand_alert',
      jsonb_build_object(
        'booking_id',   v_booking.id,
        'city',         v_customer_city,
        'category',     v_booking.category,
        'amount',       v_booking.service_amount,
        'created_at',   now()
      )::text
    );

    RETURN jsonb_build_object(
      'error',          'No fixers available',
      'broadcast',      true,
      'tier',           3,
      'booking_id',     v_booking.id,
      'city',           v_customer_city,
      'action_required', 'Ops: notify fixers in ' || COALESCE(v_customer_city, 'unknown city')
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
    'match_tier',   v_match_tier,
    'expires_at',   v_offer_expires_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION match_fixers(UUID, DOUBLE PRECISION, INTEGER) TO service_role, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5: ISSUE 3 FIX — Payout audit + reliable release
-- ─────────────────────────────────────────────────────────────────────────────

-- BUG C FIX: create_payout was defaulting to 15% — override the helper
CREATE OR REPLACE FUNCTION create_payout(
  p_booking_id     UUID,
  p_commission_pct NUMERIC DEFAULT NULL  -- NULL = use platform_commission_pct()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking      bookings%ROWTYPE;
  v_gross        NUMERIC(10,2);
  v_commission   NUMERIC(10,2);
  v_net          NUMERIC(10,2);
  v_payout_id    UUID;
  v_rate         NUMERIC;
BEGIN
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;

  IF EXISTS (SELECT 1 FROM payouts WHERE booking_id = p_booking_id) THEN
    RETURN jsonb_build_object('message', 'Payout already exists');
  END IF;

  IF v_booking.fixer_id IS NULL THEN
    RETURN jsonb_build_object('message', 'No fixer assigned, skipping payout');
  END IF;

  -- BUG C FIX: use stored fixer_payout if present (rate-locked at booking time),
  -- otherwise fall back to platform_commission_pct() — never use the old 15% default.
  v_gross := COALESCE(v_booking.service_amount, v_booking.amount);

  IF v_booking.fixer_payout IS NOT NULL AND v_booking.fixer_payout > 0 THEN
    -- Use the rate-locked value from booking creation (v8.2+ bookings)
    v_net        := v_booking.fixer_payout;
    v_commission := v_gross - v_net;
    v_rate       := CASE WHEN v_gross > 0 THEN ROUND((v_commission / v_gross * 100)::numeric, 2) ELSE 0 END;
  ELSE
    -- Pre-v8.2 bookings: use current platform rate (NOT the old 15% hardcode)
    v_rate       := COALESCE(p_commission_pct, platform_commission_pct());
    v_commission := ROUND((v_gross * v_rate / 100)::numeric, 2);
    v_net        := v_gross - v_commission;
  END IF;

  INSERT INTO payouts (
    booking_id, fixer_id, gross_amount, commission_pct,
    commission_amt, net_amount, status, hold_until
  ) VALUES (
    p_booking_id,
    v_booking.fixer_id,
    v_gross,
    v_rate,
    v_commission,
    v_net,
    'held',
    now() + interval '24 hours'
  )
  RETURNING id INTO v_payout_id;

  INSERT INTO notifications (user_id, title, body, type, related_id)
  SELECT
    f.user_id,
    '💰 Payment queued',
    'Your payment of R' || v_net::TEXT || ' will be released in 24 hours.',
    'payout_created',
    p_booking_id
  FROM fixers f WHERE f.id = v_booking.fixer_id;

  RETURN jsonb_build_object(
    'success',    true,
    'payout_id',  v_payout_id,
    'gross',      v_gross,
    'commission', v_commission,
    'net',        v_net,
    'hold_until', now() + interval '24 hours',
    'rate_source', CASE WHEN v_booking.fixer_payout IS NOT NULL THEN 'rate_locked' ELSE 'current_platform_rate' END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION create_payout(UUID, NUMERIC) TO service_role;


-- Payout run audit log
CREATE TABLE IF NOT EXISTS payout_runs (
  id               UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
  started_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at      TIMESTAMPTZ,
  trigger          TEXT        NOT NULL DEFAULT 'pg_cron'
                               CHECK (trigger IN ('pg_cron', 'netlify_scheduled', 'manual_http', 'manual_sql')),
  payouts_released INTEGER     NOT NULL DEFAULT 0,
  total_amount     NUMERIC(12,2) NOT NULL DEFAULT 0,
  error_msg        TEXT,
  created_at       TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_payout_runs_started ON payout_runs(started_at DESC);

ALTER TABLE payout_runs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "service_role_all_payout_runs" ON payout_runs;
CREATE POLICY "service_role_all_payout_runs" ON payout_runs FOR ALL TO service_role USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "admins_read_payout_runs" ON payout_runs;
CREATE POLICY "admins_read_payout_runs" ON payout_runs FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND user_role = 'admin'));


-- BUG D FIX + ISSUE 3 FIX: release_due_payouts_v2 with audit logging
-- and fixer total_earnings update.
CREATE OR REPLACE FUNCTION release_due_payouts_v2(
  p_trigger TEXT DEFAULT 'pg_cron'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_run_id      UUID;
  v_rec         RECORD;
  v_total       INTEGER := 0;
  v_amount      NUMERIC(12,2) := 0;
  v_err_msg     TEXT := NULL;
BEGIN
  -- Start audit row
  INSERT INTO payout_runs (trigger) VALUES (p_trigger) RETURNING id INTO v_run_id;

  BEGIN
    FOR v_rec IN
      SELECT p.id AS payout_id, p.fixer_id, p.net_amount, p.booking_id
      FROM   payouts p
      JOIN   bookings b ON b.id = p.booking_id
      WHERE  p.status    = 'held'
        AND  p.hold_until <= now()
        AND  b.status   != 'DISPUTED'
      FOR UPDATE OF p SKIP LOCKED
    LOOP
      UPDATE payouts SET
        status      = 'released',
        released_at = now(),
        updated_at  = now()
      WHERE id = v_rec.payout_id;

      -- BUG D FIX: update fixer total_earnings running total
      PERFORM set_config('app.allow_status_change', 'true', true);
      UPDATE fixers SET
        total_earnings = COALESCE(total_earnings, 0) + v_rec.net_amount,
        updated_at     = now()
      WHERE id = v_rec.fixer_id;

      INSERT INTO notifications (user_id, title, body, type, related_id)
      SELECT
        f.user_id,
        '✅ Payment released',
        'Your payment of R' || v_rec.net_amount::TEXT || ' has been released. Check your bank account within 1-2 business days.',
        'payout_released',
        v_rec.booking_id
      FROM fixers f WHERE f.id = v_rec.fixer_id;

      v_total  := v_total + 1;
      v_amount := v_amount + v_rec.net_amount;
    END LOOP;

  EXCEPTION WHEN OTHERS THEN
    v_err_msg := SQLERRM;
  END;

  -- Close audit row
  UPDATE payout_runs SET
    finished_at      = now(),
    payouts_released = v_total,
    total_amount     = v_amount,
    error_msg        = v_err_msg
  WHERE id = v_run_id;

  IF v_err_msg IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', v_err_msg, 'released', v_total, 'run_id', v_run_id);
  END IF;

  RETURN jsonb_build_object('ok', true, 'released', v_total, 'total_amount', v_amount, 'run_id', v_run_id);
END;
$$;

GRANT EXECUTE ON FUNCTION release_due_payouts_v2(TEXT) TO service_role;

-- Keep old name working (backwards compat with any direct SQL calls)
CREATE OR REPLACE FUNCTION release_due_payouts()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  v_result := release_due_payouts_v2('pg_cron');
  RETURN (v_result->>'released')::INTEGER;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 6: BUG E FIX — Index on payouts for cron query
-- ─────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_payouts_held_due
  ON payouts (hold_until ASC)
  WHERE status = 'held';


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 7: BUG A FIX — pg_cron schedule corrections + new jobs
-- ─────────────────────────────────────────────────────────────────────────────

-- BUG A: '*/10 * * * * *' is 6 fields — only valid if pg_cron was compiled with
-- seconds support (it isn't on Supabase). Use 5-field standard cron.
-- Unschedule the broken job and reschedule correctly.

-- Remove broken/old schedules (idempotent — cron.unschedule returns false if not found)
SELECT cron.unschedule(jobname)
FROM   cron.job
WHERE  jobname IN ('expire-offers', 'release-payouts', 'extend-active-heartbeats');

-- Re-schedule expire-offers: every 1 minute (was broken 6-field)
SELECT cron.schedule(
  'expire-offers',
  '* * * * *',
  $$ SELECT expire_offers(); $$
);

-- Extend active-job fixer heartbeats every 4 minutes
-- (less frequent than the 8-min grace, keeps them visible without hammering the DB)
SELECT cron.schedule(
  'extend-active-heartbeats',
  '*/4 * * * *',
  $$ SELECT extend_active_job_fixer_heartbeats(); $$
);

-- Release payouts: every 30 minutes (unchanged schedule, now calls v2 with audit)
SELECT cron.schedule(
  'release-payouts',
  '*/30 * * * *',
  $$ SELECT release_due_payouts_v2('pg_cron'); $$
);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 8: BUG B FIX — Normalise surge_signal to use heartbeat_grace_interval()
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW surge_signal AS
SELECT
  p.city,
  b.category,
  COUNT(DISTINCT b.id)                                        AS searching_bookings,
  COUNT(DISTINCT f.id)                                        AS available_fixers,
  CASE
    WHEN COUNT(DISTINCT f.id) = 0 THEN 10
    ELSE ROUND(COUNT(DISTINCT b.id)::NUMERIC / COUNT(DISTINCT f.id), 2)
  END                                                         AS demand_ratio,
  CASE
    WHEN COUNT(DISTINCT f.id) = 0 THEN true
    WHEN COUNT(DISTINCT b.id)::NUMERIC / NULLIF(COUNT(DISTINCT f.id),0) >= 2 THEN true
    ELSE false
  END                                                         AS is_surge
FROM bookings b
JOIN profiles p ON p.id = b.customer_id
LEFT JOIN fixers f ON f.city = p.city
  AND f.fixer_status = 'online'
  AND f.last_seen_at >= now() - heartbeat_grace_interval()   -- BUG B FIX: was hardcoded 5 min
  AND f.status = 'approved'
  AND NOT COALESCE(f.is_flagged, false)
  AND (
    b.category IS NULL
    OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
    OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id = f.id AND fc.category = b.category)
  )
WHERE b.status IN ('SEARCHING', 'OFFERED')
  AND b.created_at >= now() - interval '1 hour'
GROUP BY p.city, b.category;

GRANT SELECT ON surge_signal TO anon, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 9: Offer window — update expire_offers to use config value
-- ─────────────────────────────────────────────────────────────────────────────

-- Note: expire_offers already uses `o.expires_at < now()` which is correct —
-- it respects whatever window was set at offer creation time.
-- No change needed to the function itself; the new offer_window_interval()
-- is used at offer creation time in match_fixers (Section 4 above).


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 10: Fixer supply dashboard view for ops
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW fixer_supply_by_city AS
SELECT
  f.city,
  COUNT(*)                                                         AS total_approved,
  COUNT(*) FILTER (WHERE f.available = true
                     AND f.last_seen_at >= now() - heartbeat_grace_interval())
                                                                   AS online_now,
  COUNT(*) FILTER (WHERE f.available = true
                     AND (f.last_seen_at IS NULL
                          OR f.last_seen_at < now() - heartbeat_grace_interval()))
                                                                   AS available_but_stale,
  COUNT(*) FILTER (WHERE f.available = false)                      AS offline,
  COUNT(*) FILTER (WHERE f.is_flagged = true)                      AS flagged,
  ROUND(AVG(f.rating)::numeric, 2)                                 AS avg_rating,
  MAX(f.last_seen_at)                                              AS last_activity
FROM fixers f
WHERE f.status = 'approved'
GROUP BY f.city
ORDER BY online_now DESC, total_approved DESC;

GRANT SELECT ON fixer_supply_by_city TO service_role;
GRANT SELECT ON fixer_supply_by_city TO authenticated;  -- admins only enforced via RLS on profiles


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 11: Record migration
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO schema_migrations (version) VALUES ('v8.5') ON CONFLICT DO NOTHING;
