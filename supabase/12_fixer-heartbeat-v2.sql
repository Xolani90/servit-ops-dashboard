-- ═══════════════════════════════════════════════════════════════
-- 12_fixer-heartbeat-v2 — FIX E
--
-- app.js v8.5 calls supabaseClient.rpc('fixer_heartbeat_v2', ...)
-- but this function was never written to a migration file.
-- Without it every heartbeat ping fails with "function not found",
-- last_seen_at is never updated, and match_fixers excludes all fixers.
--
-- Run this in Supabase SQL Editor (Dashboard → SQL Editor → New Query)
-- before deploying the v8.6 frontend.
--
-- Parameters accepted from app.js:
--   p_user_id    UUID     — auth.uid() of the fixer
--   p_visibility TEXT     — 'visible' | 'hidden' (Page Visibility API)
--   p_app_state  TEXT     — 'foreground' | 'background'
--   p_lat        FLOAT8   — optional GPS latitude
--   p_lng        FLOAT8   — optional GPS longitude
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION fixer_heartbeat_v2(
  p_user_id    UUID,
  p_visibility TEXT             DEFAULT 'visible',
  p_app_state  TEXT             DEFAULT 'foreground',
  p_lat        DOUBLE PRECISION DEFAULT NULL,
  p_lng        DOUBLE PRECISION DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fixer_id UUID;
BEGIN
  -- Resolve fixer from user_id (avoids extra round-trip from client)
  SELECT id INTO v_fixer_id
  FROM   fixers
  WHERE  user_id = p_user_id
    AND  status  = 'approved'
  LIMIT  1;

  IF v_fixer_id IS NULL THEN
    -- Soft fail — not a registered fixer (e.g. customer accidentally hitting endpoint)
    RETURN jsonb_build_object('ok', false, 'reason', 'not_a_fixer');
  END IF;

  -- Update last_seen_at always; update coordinates only when provided
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
    UPDATE fixers
    SET
      last_seen_at = now(),
      latitude     = p_lat,
      longitude    = p_lng,
      updated_at   = now()
    WHERE id = v_fixer_id;
  ELSE
    UPDATE fixers
    SET
      last_seen_at = now(),
      updated_at   = now()
    WHERE id = v_fixer_id;
  END IF;

  RETURN jsonb_build_object(
    'ok',         true,
    'fixer_id',   v_fixer_id,
    'visibility', p_visibility,
    'app_state',  p_app_state,
    'ts',         now()
  );
END;
$$;

-- Grant execute to authenticated users (anon key callers with a valid session)
GRANT EXECUTE ON FUNCTION fixer_heartbeat_v2(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION)
  TO authenticated;

-- ── Also update the schema comment to reflect the 8-minute window ──
-- (The index below is informational — it already exists from schema.sql)
-- Reminder: match_fixers now uses interval '8 minutes' (fixed in 06_match-fixers.sql)
COMMENT ON COLUMN fixers.last_seen_at IS
  'Updated every 60s by fixer_heartbeat_v2. match_fixers excludes fixers not seen within 8 minutes.';
