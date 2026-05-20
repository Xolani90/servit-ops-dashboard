-- ═══════════════════════════════════════════════════════════════════════════
-- SERVIT v8.6 — Bug-Fix Migration
-- Run AFTER v8_5_production.sql
-- Idempotent — safe to re-run.
--
-- Fixes addressed in this file:
--
--  BUG 4 (retry-matching fires during 90 s offer window)
--    The retry-matching cron runs every 30 s via pg_cron seconds syntax
--    ('*/30 * * * * *') which is invalid on Supabase's standard pg_cron.
--    Even if corrected to '*/2 * * * *' (every 2 min), the WHERE clause
--    never guards the live offer window — it can re-match a booking that
--    still has an outstanding offer, sending a duplicate offer to a second
--    fixer before the first fixer's 90 s has elapsed.
--    FIX: Reschedule to every 2 minutes (minimum pg_cron resolution that
--    makes sense for a 90 s window) AND add offer_expires_at > now() guard
--    so an in-flight offer is never trampled.
--
--  BUG 5 (no rate limiting on Netlify functions)
--    create-booking, update-location, accept-offer have no server-side
--    throttle.  A valid JWT can hammer the DB indefinitely.
--    FIX (DB-side): Add a rate_limit_hits table and
--    check_rate_limit(p_user_id, p_action, p_max_calls, p_window_seconds)
--    helper that Netlify functions call before doing real work.
--    Netlify-side wrappers are provided separately (see netlify/functions/).
--
--  BUG 6 (analytics_events table missing)
--    trackEvent() in app.js silently fails on every page because the table
--    was referenced but never created in any migration.
--    FIX: Create the table, index, and RLS policy here.
--
-- ═══════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1 — BUG 4 FIX: Rescue retry-matching cron
-- ─────────────────────────────────────────────────────────────────────────────

-- Remove the broken seconds-syntax schedule ('*/30 * * * * *' = 6 fields,
-- invalid on Supabase pg_cron) and replace with a 5-field schedule that:
--   • Runs every 2 minutes (safe margin above the 90 s offer window)
--   • Guards offer_expires_at > now() so a live offer is never clobbered
--
-- The old retry-matching job may or may not exist depending on migration order,
-- so unschedule is wrapped in a DO block to swallow "not found" errors.

DO $$
BEGIN
  PERFORM cron.unschedule('retry-matching');
EXCEPTION WHEN OTHERS THEN
  NULL; -- job didn't exist; harmless
END;
$$;

SELECT cron.schedule(
  'retry-matching',
  '*/2 * * * *',    -- every 2 minutes; valid 5-field pg_cron syntax
  $$
    SELECT match_fixers(id)
    FROM   bookings
    WHERE  status         = 'SEARCHING'
      AND  payment_status = 'paid'
      AND  (
        -- No outstanding offer at all
        current_offer_id IS NULL
        -- OR the current offer has already expired (90 s window closed)
        OR offer_expires_at < now()
        -- BUG 4 FIX: was missing — previously re-matched even with a live offer
      )
      AND  (
        booking_mode = 'asap'
        OR (booking_mode = 'scheduled' AND scheduled_for <= now() + interval '2 hours')
      );
  $$
);


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2 — BUG 5 FIX: DB-side rate limiting infrastructure
-- ─────────────────────────────────────────────────────────────────────────────

-- Table: rate_limit_hits
-- Tracks call timestamps per (user_id, action) so we can enforce sliding-window
-- limits without an external Redis dependency.
-- Rows older than the longest window (currently 1 hour) are pruned automatically.

CREATE TABLE IF NOT EXISTS rate_limit_hits (
  id         BIGSERIAL    PRIMARY KEY,
  user_id    UUID         NOT NULL,
  action     TEXT         NOT NULL,
  hit_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS rate_limit_hits_lookup_idx
  ON rate_limit_hits (user_id, action, hit_at);

-- Prune rows older than 1 hour every 10 minutes so the table stays tiny.
DO $$
BEGIN
  PERFORM cron.unschedule('prune-rate-limit-hits');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

SELECT cron.schedule(
  'prune-rate-limit-hits',
  '*/10 * * * *',
  $$ DELETE FROM rate_limit_hits WHERE hit_at < now() - interval '1 hour'; $$
);

-- RLS: service_role writes; no direct user access
ALTER TABLE rate_limit_hits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rate_limit_hits_service_only ON rate_limit_hits;
CREATE POLICY rate_limit_hits_service_only ON rate_limit_hits
  USING (false)       -- users cannot read
  WITH CHECK (false); -- users cannot write; service_role bypasses RLS

GRANT ALL ON rate_limit_hits TO service_role;

-- Function: check_rate_limit
-- Returns TRUE if the call is allowed, FALSE if the limit is exceeded.
-- Also records the hit atomically so the count is always accurate.
--
-- Usage from Netlify (via RPC with service key):
--   const { data: allowed } = await supabase.rpc('check_rate_limit', {
--     p_user_id: user.id,
--     p_action: 'create_booking',
--     p_max_calls: 10,
--     p_window_seconds: 3600,
--   });
--   if (!allowed) return { statusCode: 429, body: 'Rate limit exceeded' };
--
-- Recommended limits (enforced in each Netlify function):
--   create_booking  : 10 per hour
--   accept_offer    : 20 per hour
--   update_location : 120 per hour (= every 30 s; generous for a heartbeat)

CREATE OR REPLACE FUNCTION check_rate_limit(
  p_user_id         UUID,
  p_action          TEXT,
  p_max_calls       INT,
  p_window_seconds  INT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count   INT;
  v_window  INTERVAL;
BEGIN
  v_window := (p_window_seconds || ' seconds')::INTERVAL;

  -- Count hits within the sliding window
  SELECT COUNT(*) INTO v_count
  FROM   rate_limit_hits
  WHERE  user_id = p_user_id
    AND  action  = p_action
    AND  hit_at >= now() - v_window;

  IF v_count >= p_max_calls THEN
    RETURN false;  -- limit exceeded; do NOT record another hit
  END IF;

  -- Record this hit
  INSERT INTO rate_limit_hits (user_id, action) VALUES (p_user_id, p_action);
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION check_rate_limit(UUID, TEXT, INT, INT) TO service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3 — BUG 6 FIX: Create analytics_events table
-- ─────────────────────────────────────────────────────────────────────────────
-- trackEvent() in app.js inserts into this table on every meaningful user
-- action.  Without the table every page load silently fails the insert,
-- losing all analytics data.

CREATE TABLE IF NOT EXISTS analytics_events (
  id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID         REFERENCES auth.users(id) ON DELETE SET NULL,
  session_id  TEXT,
  event_name  TEXT         NOT NULL,
  properties  JSONB        NOT NULL DEFAULT '{}',
  url         TEXT,
  user_agent  TEXT,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Index for time-series queries and per-user funnels
CREATE INDEX IF NOT EXISTS analytics_events_name_time_idx
  ON analytics_events (event_name, created_at DESC);

CREATE INDEX IF NOT EXISTS analytics_events_user_idx
  ON analytics_events (user_id, created_at DESC)
  WHERE user_id IS NOT NULL;

-- Partition-friendly: prune events older than 90 days to keep table small.
-- Adjust the interval to your retention policy.
DO $$
BEGIN
  PERFORM cron.unschedule('prune-analytics-events');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

SELECT cron.schedule(
  'prune-analytics-events',
  '0 3 * * *',  -- daily at 03:00 UTC
  $$ DELETE FROM analytics_events WHERE created_at < now() - interval '90 days'; $$
);

-- RLS: authenticated users can insert their own events only.
-- No user can read analytics (ops uses service_role / Supabase dashboard).
ALTER TABLE analytics_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS analytics_events_insert_own ON analytics_events;
CREATE POLICY analytics_events_insert_own ON analytics_events
  FOR INSERT
  TO authenticated
  WITH CHECK (
    -- Allow NULL user_id (pre-login events) or own user_id
    user_id IS NULL OR user_id = auth.uid()
  );

-- Anon users can also fire events (pre-login funnel tracking)
DROP POLICY IF EXISTS analytics_events_insert_anon ON analytics_events;
CREATE POLICY analytics_events_insert_anon ON analytics_events
  FOR INSERT
  TO anon
  WITH CHECK (user_id IS NULL);

GRANT INSERT ON analytics_events TO authenticated, anon;
GRANT ALL    ON analytics_events TO service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4 — Migration record
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS schema_migrations (
  version     TEXT        PRIMARY KEY,
  applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO schema_migrations (version) VALUES ('v8.6')
ON CONFLICT (version) DO NOTHING;