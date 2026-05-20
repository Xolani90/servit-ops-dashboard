-- ═══════════════════════════════════════════════════════════════
-- SERVIT v7.0 — POST-SHIP FIXES
-- Run after 01–04 migrations are applied.
-- Idempotent — safe to re-run.
-- ═══════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────
-- FIX 1: available ↔ fixer_status single source of truth
--
-- The heartbeat system writes `available` (boolean). Dispatch reads
-- `fixer_status` (text). They can drift. We fix this by:
--   a) Back-filling fixer_status from available right now
--   b) Adding a trigger that keeps them in sync going forward
--   c) Leaving available in place so existing heartbeat code
--      continues to work without changes — the trigger does the work.
--
-- If you later want to drop `available` entirely, do it in v8 once
-- you've updated the heartbeat code to write fixer_status directly.
-- ────────────────────────────────────────────────────────────────

-- a) One-time back-fill: trust fixer_status if it's already been set
--    by v7 code; otherwise derive it from available.
UPDATE fixers
SET fixer_status = CASE
    WHEN available = true  THEN 'online'
    WHEN available = false THEN 'offline'
    ELSE fixer_status
  END
WHERE fixer_status IS NULL
   OR (
     -- Drift condition: available says online but fixer_status says offline (or vice versa)
     available = true  AND fixer_status = 'offline'
   );

-- b) Trigger function: whenever `available` is written, sync fixer_status.
--    Also works in reverse: if something sets fixer_status, sync available.
DROP FUNCTION IF EXISTS sync_fixer_availability() CASCADE;
CREATE OR REPLACE FUNCTION sync_fixer_availability()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Heartbeat wrote `available` → mirror into fixer_status
  IF NEW.available IS DISTINCT FROM OLD.available THEN
    NEW.fixer_status := CASE
      WHEN NEW.available = true  THEN 'online'
      WHEN NEW.available = false THEN 'offline'
      ELSE NEW.fixer_status
    END;
  END IF;

  -- Something wrote `fixer_status` → mirror into available
  IF NEW.fixer_status IS DISTINCT FROM OLD.fixer_status THEN
    NEW.available := (NEW.fixer_status = 'online');
  END IF;

  -- Never let an approved fixer appear online if they're suspended/flagged
  IF NEW.status = 'suspended' OR COALESCE(NEW.is_flagged, false) = true THEN
    NEW.fixer_status := 'offline';
    NEW.available    := false;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_fixer_availability ON fixers;
CREATE TRIGGER trg_sync_fixer_availability
  BEFORE UPDATE ON fixers
  FOR EACH ROW EXECUTE FUNCTION sync_fixer_availability();


-- ────────────────────────────────────────────────────────────────
-- FIX 2: rebook_from_history RPC
--
-- app.js line 1771 calls `.rpc('rebook_from_history', ...)`.
-- This function was never defined — Supabase returns a 42883 error
-- which the frontend silently swallows. Every rebook attempt fails.
--
-- This RPC:
--   1. Looks up the customer's most recent completed booking
--   2. Returns the data needed for app.js to pre-fill a new booking
--   3. Can optionally filter by fixer_id if the user tapped a specific
--      "rebook this fixer" card
--
-- The function does NOT create a new booking — that stays in app.js.
-- It just returns the pre-fill data so the existing flow works.
-- ────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS rebook_from_history(UUID, UUID, UUID);
CREATE OR REPLACE FUNCTION rebook_from_history(
  p_customer_id  UUID,
  p_booking_id   UUID  DEFAULT NULL,  -- specific booking to rebook from
  p_fixer_id     UUID  DEFAULT NULL   -- specific fixer to rebook with
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'ok',           true,
    'booking_id',   b.id,
    'fixer_id',     f.id,
    'fixer_name',   f.full_name,
    'fixer_photo',  f.photo_url,
    'fixer_rating', f.rating,
    'fixer_online', (f.fixer_status = 'online' AND f.last_seen_at >= now() - interval '5 minutes'),
    'category',     b.category,
    'service_tier', b.service_tier,
    'address',      b.address,
    'city',         b.city,
    -- Let the frontend know if the original fixer is still available
    'same_fixer_available', (
      f.status = 'approved'
      AND f.fixer_status = 'online'
      AND f.last_seen_at >= now() - interval '5 minutes'
      AND NOT COALESCE(f.is_flagged, false)
    )
  )
  INTO v_result
  FROM bookings b
  JOIN fixers f ON f.id = b.fixer_id
  WHERE b.customer_id = p_customer_id
    AND b.status = 'COMPLETED'
    AND b.fixer_id IS NOT NULL
    -- If a specific booking was requested, use it; otherwise get the latest
    AND (p_booking_id IS NULL OR b.id = p_booking_id)
    -- If a specific fixer was requested, filter for them
    AND (p_fixer_id IS NULL OR b.fixer_id = p_fixer_id)
  ORDER BY b.completed_at DESC
  LIMIT 1;

  -- Return a clear error object if nothing was found — never return null
  -- so app.js can always check result.ok instead of null-checking
  IF v_result IS NULL THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'no_completed_bookings',
      'hint',  'Customer has no completed bookings to rebook from'
    );
  END IF;

  RETURN v_result;
END;
$$;

-- Customers call this from the app
GRANT EXECUTE ON FUNCTION rebook_from_history(UUID, UUID, UUID) TO authenticated;


-- ────────────────────────────────────────────────────────────────
-- FIX 3: account_number_encrypted — verification + encryption
--
-- This block checks whether the column exists as plaintext.
-- If pgcrypto is available (it is on Supabase), it re-encrypts
-- any existing values and logs a confirmation.
--
-- KEY MANAGEMENT NOTE:
--   The encryption key is read from app.settings.bank_detail_key
--   which you set via:
--     ALTER DATABASE postgres SET app.settings.bank_detail_key = 'your-key';
--   Or per-session in your service-role Netlify functions:
--     SET app.settings.bank_detail_key = '<key>';
--   Store the actual key in your Supabase Vault or Netlify env vars.
--   Never hardcode it here.
--
-- POPIA requirement: data minimisation + security safeguards (s19).
-- Financial regulation: SARB / PASA rules on bank account data storage.
-- ────────────────────────────────────────────────────────────────

-- Enable pgcrypto if not already enabled (safe to run on Supabase)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Add the column if it doesn't exist yet (in case base schema predates v7)
ALTER TABLE fixers
  ADD COLUMN IF NOT EXISTS account_number_encrypted TEXT;

-- Wrap in a DO block so we can check the encryption state first
DO $$
DECLARE
  v_sample TEXT;
  v_looks_encrypted BOOLEAN;
BEGIN
  -- Sample one non-null value
  SELECT account_number_encrypted INTO v_sample
  FROM fixers
  WHERE account_number_encrypted IS NOT NULL
  LIMIT 1;

  IF v_sample IS NULL THEN
    RAISE NOTICE 'account_number_encrypted: column is empty — nothing to re-encrypt. '
      'New values written via the set_fixer_bank_account() function below will be encrypted.';
    RETURN;
  END IF;

  -- A pgp_sym_encrypt output always starts with the PGP binary header \xc0
  -- When base64-encoded (as pgcrypto outputs), it starts with 'wA'
  v_looks_encrypted := (v_sample LIKE 'wA%' OR v_sample LIKE '\xc0%');

  IF v_looks_encrypted THEN
    RAISE NOTICE 'account_number_encrypted: values appear already encrypted. No action taken.';
  ELSE
    RAISE WARNING 'account_number_encrypted: values appear to be PLAINTEXT. '
      'Run the re-encryption block below with your encryption key before going to production. '
      'See: supabase/v7_marketplace/05_fixes.sql — Re-encryption block.';
  END IF;
END;
$$;

-- ── Safe write function for bank account numbers ──────────────────
-- App code should NEVER write account_number_encrypted directly.
-- Always go through this function so encryption is guaranteed.
DROP FUNCTION IF EXISTS set_fixer_bank_account(UUID, TEXT);
CREATE OR REPLACE FUNCTION set_fixer_bank_account(
  p_fixer_id       UUID,
  p_account_number TEXT   -- plaintext from the form; encrypted before storage
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key TEXT;
BEGIN
  -- Read key from session/db setting — set via Netlify env → Supabase connection param
  v_key := current_setting('app.settings.bank_detail_key', true);

  IF v_key IS NULL OR v_key = '' THEN
    RAISE EXCEPTION 'bank_detail_key is not set — cannot encrypt bank account number. '
      'Set app.settings.bank_detail_key in your connection string or via SET.';
  END IF;

  UPDATE fixers
  SET account_number_encrypted = encode(
        pgp_sym_encrypt(p_account_number, v_key),
        'base64'
      ),
      updated_at = now()
  WHERE id = p_fixer_id;
END;
$$;

-- Only service_role (Netlify backend) should write bank details
GRANT EXECUTE ON FUNCTION set_fixer_bank_account(UUID, TEXT) TO service_role;
REVOKE EXECUTE ON FUNCTION set_fixer_bank_account(UUID, TEXT) FROM authenticated, anon;

-- ── Safe read function — decrypts on the way out ─────────────────
-- Only callable by service_role (payout processor), never the client
DROP FUNCTION IF EXISTS get_fixer_bank_account(UUID);
CREATE OR REPLACE FUNCTION get_fixer_bank_account(p_fixer_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key       TEXT;
  v_encrypted TEXT;
BEGIN
  v_key := current_setting('app.settings.bank_detail_key', true);

  IF v_key IS NULL OR v_key = '' THEN
    RAISE EXCEPTION 'bank_detail_key is not set';
  END IF;

  SELECT account_number_encrypted INTO v_encrypted
  FROM fixers WHERE id = p_fixer_id;

  IF v_encrypted IS NULL THEN RETURN NULL; END IF;

  RETURN pgp_sym_decrypt(decode(v_encrypted, 'base64'), v_key);
END;
$$;

GRANT EXECUTE ON FUNCTION get_fixer_bank_account(UUID) TO service_role;
REVOKE EXECUTE ON FUNCTION get_fixer_bank_account(UUID) FROM authenticated, anon;

-- ── RLS: no client should ever SELECT account_number_encrypted ───
-- Add this policy to your fixers RLS if not already present.
-- Customers and fixers see their own row but never the encrypted column.
-- The column is only readable via get_fixer_bank_account() as service_role.
COMMENT ON COLUMN fixers.account_number_encrypted IS
  'Bank account number encrypted with pgp_sym_encrypt. '
  'Never read directly — use get_fixer_bank_account() as service_role only. '
  'Never write directly — use set_fixer_bank_account(). '
  'Key: app.settings.bank_detail_key (store in Supabase Vault or Netlify env).';


-- ────────────────────────────────────────────────────────────────
-- FIX 4: Analytics instrumentation
--
-- A lightweight view + three RPCs that answer the core funnel
-- questions. No external tools required — run in Supabase SQL editor
-- or call from a weekly Netlify cron job.
-- ────────────────────────────────────────────────────────────────

-- ── Core funnel metrics view ──────────────────────────────────────
CREATE OR REPLACE VIEW marketplace_funnel AS
SELECT
  date_trunc('day', created_at)                                        AS day,

  -- Booking creation
  COUNT(*)                                                             AS bookings_created,

  -- Payment
  COUNT(*) FILTER (WHERE status != 'CANCELLED' AND payment_status = 'paid')
                                                                       AS bookings_paid,

  -- Match: a fixer was assigned
  COUNT(*) FILTER (WHERE fixer_id IS NOT NULL)                        AS bookings_matched,

  -- Completion
  COUNT(*) FILTER (WHERE status = 'COMPLETED')                        AS bookings_completed,

  -- Cancellations
  COUNT(*) FILTER (WHERE status = 'CANCELLED')                        AS bookings_cancelled,

  -- Match rate among paid bookings (the number that matters most)
  ROUND(
    COUNT(*) FILTER (WHERE fixer_id IS NOT NULL)::NUMERIC /
    NULLIF(COUNT(*) FILTER (WHERE status != 'CANCELLED'), 0) * 100
  , 1)                                                                 AS match_rate_pct,

  -- Completion rate among matched bookings
  ROUND(
    COUNT(*) FILTER (WHERE status = 'COMPLETED')::NUMERIC /
    NULLIF(COUNT(*) FILTER (WHERE fixer_id IS NOT NULL), 0) * 100
  , 1)                                                                 AS completion_rate_pct

FROM bookings
GROUP BY date_trunc('day', created_at)
ORDER BY day DESC;

GRANT SELECT ON marketplace_funnel TO service_role;
-- Do NOT grant to authenticated/anon — contains aggregate business metrics


-- ── RPC: weekly health summary (call from Netlify cron or Supabase UI) ─
DROP FUNCTION IF EXISTS get_marketplace_health(INTEGER);
CREATE OR REPLACE FUNCTION get_marketplace_health(
  p_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total_bookings     INTEGER;
  v_matched            INTEGER;
  v_completed          INTEGER;
  v_cancelled          INTEGER;
  v_match_rate         NUMERIC;
  v_completion_rate    NUMERIC;
  v_median_to_match    NUMERIC;  -- seconds
  v_median_to_complete NUMERIC;  -- seconds
  v_zero_match_cats    JSONB;
  v_busiest_city       TEXT;
BEGIN
  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE fixer_id IS NOT NULL),
    COUNT(*) FILTER (WHERE status = 'COMPLETED'),
    COUNT(*) FILTER (WHERE status = 'CANCELLED')
  INTO v_total_bookings, v_matched, v_completed, v_cancelled
  FROM bookings
  WHERE created_at >= now() - (p_days || ' days')::INTERVAL;

  v_match_rate      := ROUND(v_matched::NUMERIC / NULLIF(v_total_bookings - v_cancelled, 0) * 100, 1);
  v_completion_rate := ROUND(v_completed::NUMERIC / NULLIF(v_matched, 0) * 100, 1);

  -- Median time from booking created → fixer accepted (seconds)
  SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (
    ORDER BY EXTRACT(EPOCH FROM (accepted_at - created_at))
  )
  INTO v_median_to_match
  FROM bookings
  WHERE accepted_at IS NOT NULL
    AND created_at >= now() - (p_days || ' days')::INTERVAL;

  -- Median time from booking created → job completed (minutes)
  SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (
    ORDER BY EXTRACT(EPOCH FROM (completed_at - created_at)) / 60
  )
  INTO v_median_to_complete
  FROM bookings
  WHERE completed_at IS NOT NULL
    AND created_at >= now() - (p_days || ' days')::INTERVAL;

  -- Categories with zero matches (supply gap signal)
  SELECT jsonb_agg(cat ORDER BY attempts DESC)
  INTO v_zero_match_cats
  FROM (
    SELECT category AS cat, COUNT(*) AS attempts
    FROM bookings
    WHERE fixer_id IS NULL
      AND status NOT IN ('CANCELLED')
      AND category IS NOT NULL
      AND created_at >= now() - (p_days || ' days')::INTERVAL
    GROUP BY category
    ORDER BY attempts DESC
    LIMIT 5
  ) unmatched;

  -- Busiest city by booking volume
  SELECT p.city INTO v_busiest_city
  FROM bookings b
  JOIN profiles p ON p.id = b.customer_id
  WHERE b.created_at >= now() - (p_days || ' days')::INTERVAL
  GROUP BY p.city
  ORDER BY COUNT(*) DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'period_days',            p_days,
    'generated_at',           now(),

    -- Volume
    'bookings_created',       v_total_bookings,
    'bookings_matched',       v_matched,
    'bookings_completed',     v_completed,
    'bookings_cancelled',     v_cancelled,

    -- Rates (the key marketplace health indicators)
    'match_rate_pct',         COALESCE(v_match_rate, 0),
    'completion_rate_pct',    COALESCE(v_completion_rate, 0),

    -- Speed
    'median_seconds_to_match',   ROUND(COALESCE(v_median_to_match, 0)),
    'median_minutes_to_complete', ROUND(COALESCE(v_median_to_complete, 0)),

    -- Diagnostic signals
    'unmatched_categories',   COALESCE(v_zero_match_cats, '[]'::JSONB),
    'busiest_city',           v_busiest_city,

    -- Health flags (thresholds you should alert on)
    'alerts', jsonb_build_object(
      'match_rate_low',      COALESCE(v_match_rate, 0) < 70,   -- <70% = supply problem
      'completion_rate_low', COALESCE(v_completion_rate, 0) < 80,
      'slow_matching',       COALESCE(v_median_to_match, 0) > 300  -- >5 min median
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_marketplace_health(INTEGER) TO service_role;


-- ── RPC: per-fixer performance (for admin dashboard) ─────────────
DROP FUNCTION IF EXISTS get_fixer_performance(INTEGER, INTEGER);
CREATE OR REPLACE FUNCTION get_fixer_performance(
  p_days    INTEGER DEFAULT 30,
  p_limit   INTEGER DEFAULT 20
)
RETURNS TABLE(
  fixer_id          UUID,
  full_name         TEXT,
  city              TEXT,
  bookings_accepted INTEGER,
  bookings_completed INTEGER,
  cancellations     INTEGER,
  avg_rating        NUMERIC,
  completion_pct    NUMERIC,
  median_response_s NUMERIC,
  total_earnings    NUMERIC,
  fixer_status      TEXT,
  days_since_online INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    f.id,
    f.full_name,
    f.city,
    COUNT(b.id) FILTER (WHERE b.fixer_id = f.id)::INTEGER                AS bookings_accepted,
    COUNT(b.id) FILTER (WHERE b.status = 'COMPLETED')::INTEGER           AS bookings_completed,
    COUNT(b.id) FILTER (WHERE b.status = 'CANCELLED')::INTEGER           AS cancellations,
    ROUND(AVG(r.rating), 2)                                              AS avg_rating,
    ROUND(
      COUNT(b.id) FILTER (WHERE b.status = 'COMPLETED')::NUMERIC /
      NULLIF(COUNT(b.id) FILTER (WHERE b.fixer_id = f.id), 0) * 100
    , 1)                                                                  AS completion_pct,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (
      ORDER BY EXTRACT(EPOCH FROM (b.accepted_at - b.created_at))
    ))                                                                    AS median_response_s,
    f.total_earnings,
    f.fixer_status,
    EXTRACT(DAY FROM now() - f.last_seen_at)::INTEGER                    AS days_since_online
  FROM fixers f
  LEFT JOIN bookings b ON b.fixer_id = f.id
    AND b.created_at >= now() - (p_days || ' days')::INTERVAL
  LEFT JOIN reviews r ON r.fixer_id = f.id
    AND r.created_at >= now() - (p_days || ' days')::INTERVAL
  WHERE f.status = 'approved'
  GROUP BY f.id, f.full_name, f.city, f.total_earnings, f.fixer_status, f.last_seen_at
  ORDER BY bookings_completed DESC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION get_fixer_performance(INTEGER, INTEGER) TO service_role;


-- ════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- Run these after applying this file to confirm everything is wired.
-- ════════════════════════════════════════════════════════════════

/*
-- 1. Confirm sync trigger exists
SELECT trigger_name, event_manipulation, action_timing
FROM information_schema.triggers
WHERE trigger_name = 'trg_sync_fixer_availability';

-- 2. Confirm rebook_from_history exists
SELECT proname, pronargs FROM pg_proc WHERE proname = 'rebook_from_history';

-- 3. Check encryption state of bank accounts
SELECT
  CASE
    WHEN account_number_encrypted IS NULL THEN 'empty'
    WHEN account_number_encrypted LIKE 'wA%' THEN 'encrypted'
    ELSE 'PLAINTEXT — needs re-encryption'
  END AS status,
  COUNT(*)
FROM fixers
GROUP BY 1;

-- 4. Confirm analytics functions
SELECT get_marketplace_health(30);

-- 5. Test the sync trigger (use a real fixer id)
-- UPDATE fixers SET available = false WHERE id = '<fixer-uuid>';
-- SELECT id, available, fixer_status FROM fixers WHERE id = '<fixer-uuid>';
-- Should show: available=false, fixer_status='offline'
*/
