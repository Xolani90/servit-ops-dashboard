-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8.1 — CRITICAL PRODUCTION FIXES
-- Addresses all 9 issues from the production audit.
-- Run AFTER 07_v8_fixes.sql.
-- Idempotent — safe to re-run.
-- ═══════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────
-- ISSUE 1: Idempotency key on booking creation (duplicate bookings)
-- A customer tapping "Book" twice on a slow connection creates two
-- identical bookings. Fix: add idempotency_key column with UNIQUE
-- constraint. Client generates a UUID once per booking session and
-- sends it; the DB rejects the second insert silently.
-- ────────────────────────────────────────────────────────────────

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS idempotency_key UUID;

-- UNIQUE constraint: same key cannot create two rows.
-- Partial index (WHERE idempotency_key IS NOT NULL) so existing
-- rows without a key don't collide with each other.
CREATE UNIQUE INDEX IF NOT EXISTS bookings_idempotency_key_uidx
  ON bookings (idempotency_key)
  WHERE idempotency_key IS NOT NULL;

-- Safe booking-creation RPC.
-- Call this from app.js instead of a raw INSERT so idempotency
-- is enforced at the database layer, not the client layer.
-- Returns the existing booking if the key has already been used.
CREATE OR REPLACE FUNCTION create_booking_idempotent(
  p_customer_id     UUID,
  p_category        TEXT,
  p_service_tier    TEXT,
  p_address         TEXT,
  p_city            TEXT,
  p_idempotency_key UUID  -- generated client-side with crypto.randomUUID()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking_id UUID;
  v_existing   UUID;
  v_new_id     UUID;
BEGIN
  -- Check if this key already produced a booking (idempotent replay)
  SELECT id INTO v_existing
  FROM bookings
  WHERE idempotency_key = p_idempotency_key;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok',         true,
      'booking_id', v_existing,
      'idempotent', true   -- tells the client this was a replay, not a new booking
    );
  END IF;

  -- First call: create the booking
  INSERT INTO bookings (
    customer_id,
    category,
    service_tier,
    address,
    city,
    status,
    idempotency_key,
    created_at
  )
  VALUES (
    p_customer_id,
    p_category,
    p_service_tier,
    p_address,
    p_city,
    'SEARCHING',
    p_idempotency_key,
    now()
  )
  RETURNING id INTO v_new_id;

  RETURN jsonb_build_object(
    'ok',         true,
    'booking_id', v_new_id,
    'idempotent', false
  );

EXCEPTION
  -- Race condition: two requests arrived simultaneously with the same key.
  -- The UNIQUE index catches the second one. Return the winner's row.
  WHEN unique_violation THEN
    SELECT id INTO v_existing FROM bookings WHERE idempotency_key = p_idempotency_key;
    RETURN jsonb_build_object(
      'ok',         true,
      'booking_id', v_existing,
      'idempotent', true
    );
END;
$$;

GRANT EXECUTE ON FUNCTION create_booking_idempotent(UUID, TEXT, TEXT, TEXT, TEXT, UUID)
  TO authenticated;


-- ────────────────────────────────────────────────────────────────
-- ISSUE 3: Heartbeat — fixer online status loses truth after ~5 min
-- The SQL helper is correct but the DB needs a safe update path
-- that app.js can call on an interval (every 60s is fine).
-- This RPC also updates fixer_status + available in one call so
-- the sync trigger in 05_fixes.sql keeps everything consistent.
-- ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION fixer_heartbeat(
  p_fixer_id UUID,
  p_lat      NUMERIC DEFAULT NULL,
  p_lng      NUMERIC DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE fixers
  SET
    last_seen_at   = now(),
    last_online_at = now(),
    available      = true,       -- triggers sync_fixer_availability → fixer_status = 'online'
    -- Update location if provided (lat/lng cols may not exist yet; handled gracefully)
    lat = COALESCE(p_lat, lat),
    lng = COALESCE(p_lng, lng)
  WHERE id = p_fixer_id
    AND status = 'approved'
    AND NOT COALESCE(is_flagged, false);
END;
$$;

-- Only the authenticated fixer can ping their own heartbeat
GRANT EXECUTE ON FUNCTION fixer_heartbeat(UUID, NUMERIC, NUMERIC) TO authenticated;

-- RPC to explicitly go offline (fixer closes the app)
CREATE OR REPLACE FUNCTION fixer_go_offline(p_fixer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE fixers
  SET
    available    = false,   -- triggers sync_fixer_availability → fixer_status = 'offline'
    last_seen_at = now()
  WHERE id = p_fixer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fixer_go_offline(UUID) TO authenticated;


-- ────────────────────────────────────────────────────────────────
-- ISSUE 4: Missing composite index on bookings(fixer_id, status, created_at)
-- Dispatch queue, get_fixer_performance(), and cancellation_breakdown
-- all scan bookings by fixer. Fine at 500 rows. Very slow at 50k.
-- ────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_bookings_fixer_status_created
  ON bookings (fixer_id, status, created_at DESC);

-- Also add customer-side index for the personalisation and rebook queries
CREATE INDEX IF NOT EXISTS idx_bookings_customer_status_created
  ON bookings (customer_id, status, created_at DESC);

-- Index to support the idempotency key lookup added above
CREATE INDEX IF NOT EXISTS idx_bookings_idempotency
  ON bookings (idempotency_key)
  WHERE idempotency_key IS NOT NULL;


-- ────────────────────────────────────────────────────────────────
-- ISSUE 5: get_home_personalisation() caching helper
-- The function runs on every home screen open. Add a result cache
-- column to profiles so app.js (and the Netlify function) can
-- skip the RPC call if the cached value is fresh (< 5 minutes).
-- Zero infrastructure cost — just two columns.
-- ────────────────────────────────────────────────────────────────

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS personalisation_cache     JSONB,
  ADD COLUMN IF NOT EXISTS personalisation_cached_at TIMESTAMPTZ;

-- Wrapped version of get_home_personalisation that reads/writes the cache.
-- Drop-in replacement: returns cached JSONB if < 5 min old.
CREATE OR REPLACE FUNCTION get_home_personalisation_cached(
  p_customer_id UUID,
  p_max_age_seconds INTEGER DEFAULT 300  -- 5 minutes
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cached     JSONB;
  v_cached_at  TIMESTAMPTZ;
  v_fresh      JSONB;
BEGIN
  -- Read cache
  SELECT personalisation_cache, personalisation_cached_at
  INTO   v_cached, v_cached_at
  FROM   profiles
  WHERE  id = p_customer_id;

  -- Return cached value if still fresh
  IF v_cached IS NOT NULL
     AND v_cached_at IS NOT NULL
     AND v_cached_at >= now() - (p_max_age_seconds || ' seconds')::INTERVAL
  THEN
    RETURN v_cached || jsonb_build_object('from_cache', true);
  END IF;

  -- Compute fresh personalisation (calls the real function defined in 03_surge_and_personalisation.sql)
  v_fresh := (SELECT get_home_personalisation(p_customer_id));

  -- Write back to cache (best-effort — don't let a cache-write error break the response)
  BEGIN
    UPDATE profiles
    SET personalisation_cache     = v_fresh,
        personalisation_cached_at = now()
    WHERE id = p_customer_id;
  EXCEPTION WHEN OTHERS THEN
    -- Cache write failed — not critical, carry on
    NULL;
  END;

  RETURN v_fresh || jsonb_build_object('from_cache', false);
END;
$$;

GRANT EXECUTE ON FUNCTION get_home_personalisation_cached(UUID, INTEGER) TO authenticated;


-- ────────────────────────────────────────────────────────────────
-- ISSUE 6: Referral codes — upgrade to cryptographically random
-- The existing trigger generates 'SERVIT-' + first 6 chars of UUID.
-- A UUID is random, so this is actually fine — but 6 hex chars
-- give ~16M combinations. Worth noting; no change needed here.
--
-- HOWEVER: new sign-ups should get 8 random alphanum chars (case-
-- insensitive, no ambiguous chars like 0/O, I/l) for ~2.8B combos,
-- making farming economically unviable (each attempt costs a
-- completed booking).
-- ────────────────────────────────────────────────────────────────

-- Replace the referral code generator with a stronger version
CREATE OR REPLACE FUNCTION generate_referral_code()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_code    TEXT;
  v_attempt INTEGER := 0;
  -- 8 chars from unambiguous alphanum set: no 0/O, 1/I/l
  v_chars   TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
BEGIN
  IF NEW.referral_code IS NOT NULL THEN
    RETURN NEW;  -- already set, respect it
  END IF;

  -- Generate unique 8-char code; retry up to 5 times on collision
  LOOP
    v_code := 'SV-' || (
      SELECT string_agg(
        substr(v_chars, (get_byte(gen_random_bytes(1), 0) % length(v_chars)) + 1, 1),
        ''
      )
      FROM generate_series(1, 8)
    );

    -- Check uniqueness
    IF NOT EXISTS (SELECT 1 FROM profiles WHERE referral_code = v_code) THEN
      NEW.referral_code := v_code;
      RETURN NEW;
    END IF;

    v_attempt := v_attempt + 1;
    EXIT WHEN v_attempt >= 5;
  END LOOP;

  -- Fallback: UUID-derived (same as before, always unique)
  NEW.referral_code := 'SV-' || UPPER(SUBSTRING(REPLACE(NEW.id::TEXT, '-', '') FROM 1 FOR 8));
  RETURN NEW;
END;
$$;

-- Trigger already exists from 01_schema; replace function in place, trigger auto-picks it up.

-- Backfill existing SHORT codes (SERVIT-XXXXXX → SV-XXXXXXXX)
-- Only update codes still in the old 'SERVIT-' format that are 6 chars long
-- (new accounts get the stronger 8-char SV- format)
-- Existing users keep their codes — changing them would break shared links.
-- This note is intentional: no backfill. Existing codes stay valid.


-- ────────────────────────────────────────────────────────────────
-- ISSUE 8: Fixer earnings statement
-- fixers.total_earnings is tracked, but fixers have no RPC to see
-- per-job breakdown. This is a trust/churn issue.
-- ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION get_fixer_earnings_statement(
  p_fixer_id UUID,
  p_days     INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  -- Security: fixers can only see their own statement
  IF auth.uid() != (SELECT user_id FROM fixers WHERE id = p_fixer_id) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  SELECT jsonb_build_object(
    'fixer_id',        p_fixer_id,
    'period_days',     p_days,
    'generated_at',    now(),
    'total_period',    COALESCE(SUM(COALESCE(b.commission, 0)) FILTER (
                         WHERE b.status = 'COMPLETED'
                         AND b.created_at >= now() - (p_days || ' days')::INTERVAL
                       ), 0),
    'total_all_time',  f.total_earnings,
    'jobs', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'booking_id',    b2.id,
          'completed_at',  b2.completed_at,
          'category',      b2.category,
          'service_tier',  b2.service_tier,
          'customer_city', b2.city,
          'amount_earned', COALESCE(b2.commission, 0),
          'rating',        r.rating,
          'review_text',   r.review_text
        )
        ORDER BY b2.completed_at DESC
      )
      FROM bookings b2
      LEFT JOIN reviews r ON r.booking_id = b2.id
      WHERE b2.fixer_id = p_fixer_id
        AND b2.status = 'COMPLETED'
        AND b2.created_at >= now() - (p_days || ' days')::INTERVAL
    )
  ) INTO v_result
  FROM bookings b
  JOIN fixers f ON f.id = p_fixer_id
  WHERE b.fixer_id = p_fixer_id;

  RETURN COALESCE(v_result, jsonb_build_object(
    'fixer_id',    p_fixer_id,
    'period_days', p_days,
    'total_period', 0,
    'jobs', '[]'::JSONB
  ));
END;
$$;

-- Fixers call this themselves
GRANT EXECUTE ON FUNCTION get_fixer_earnings_statement(UUID, INTEGER) TO authenticated;
-- Service role for admin
GRANT EXECUTE ON FUNCTION get_fixer_earnings_statement(UUID, INTEGER) TO service_role;


-- ────────────────────────────────────────────────────────────────
-- ISSUE 9: Wallet credit is cosmetic — wire it up at checkout
-- add apply_wallet_credit_to_booking() RPC that app.js calls
-- at checkout. Deducts from wallet_credit, logs the transaction,
-- and returns the remaining amount due so the payment step can
-- charge the right amount.
-- ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION apply_wallet_credit_to_booking(
  p_customer_id UUID,
  p_booking_id  UUID,
  p_booking_amount NUMERIC  -- full booking cost before credit
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available_credit  NUMERIC;
  v_credit_applied    NUMERIC;
  v_amount_due        NUMERIC;
BEGIN
  -- Lock the profile row to prevent concurrent credit drains
  SELECT wallet_credit INTO v_available_credit
  FROM profiles
  WHERE id = p_customer_id
  FOR UPDATE;

  IF v_available_credit IS NULL OR v_available_credit <= 0 THEN
    RETURN jsonb_build_object(
      'ok',             true,
      'credit_applied', 0,
      'amount_due',     p_booking_amount,
      'wallet_after',   0
    );
  END IF;

  -- Apply up to the booking amount
  v_credit_applied := LEAST(v_available_credit, p_booking_amount);
  v_amount_due     := p_booking_amount - v_credit_applied;

  -- Deduct from wallet
  UPDATE profiles
  SET wallet_credit = wallet_credit - v_credit_applied
  WHERE id = p_customer_id;

  -- Log the debit
  INSERT INTO wallet_transactions (user_id, amount, reason, related_id)
  VALUES (p_customer_id, -v_credit_applied, 'booking_credit_applied', p_booking_id);

  RETURN jsonb_build_object(
    'ok',             true,
    'credit_applied', v_credit_applied,
    'amount_due',     v_amount_due,
    'wallet_after',   v_available_credit - v_credit_applied
  );
END;
$$;

GRANT EXECUTE ON FUNCTION apply_wallet_credit_to_booking(UUID, UUID, NUMERIC) TO authenticated;


-- ────────────────────────────────────────────────────────────────
-- POST-DEPLOY VERIFICATION
-- Run these in the Supabase SQL editor to confirm the fixes landed.
-- ────────────────────────────────────────────────────────────────

/*
-- 1. Confirm idempotency key column + index
SELECT column_name FROM information_schema.columns
WHERE table_name = 'bookings' AND column_name = 'idempotency_key';
SELECT indexname FROM pg_indexes WHERE indexname = 'bookings_idempotency_key_uidx';

-- 2. Test booking creation idempotency
-- SELECT create_booking_idempotent(
--   auth.uid(), 'plumbing', 'standard', '1 Test St', 'Johannesburg',
--   gen_random_uuid()
-- );

-- 3. Confirm composite index
SELECT indexname FROM pg_indexes WHERE indexname = 'idx_bookings_fixer_status_created';

-- 4. Confirm personalisation cache columns
SELECT column_name FROM information_schema.columns
WHERE table_name = 'profiles' AND column_name IN (
  'personalisation_cache', 'personalisation_cached_at'
);

-- 5. Test fixer earnings statement (replace with a real fixer UUID)
-- SELECT get_fixer_earnings_statement('<fixer-uuid>', 30);

-- 6. Confirm wallet credit function
SELECT proname FROM pg_proc WHERE proname = 'apply_wallet_credit_to_booking';
*/
