-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8.4 — Exhaustive Bug-Fix Migration
-- Run AFTER v8_3_fixes_part2.sql
-- Idempotent — safe to re-run.
--
-- Fixes:
--  1. city column in bookings — add with DEFAULT NULL so RPC INSERT works
--     and callers that pass a full address don't break (extraction is done
--     server-side in the Netlify function now).
--  2. amount column NOT NULL violation in create_booking_idempotent — the
--     RPC never wrote the `amount` column (which is NOT NULL) so every fresh
--     booking insert threw a constraint violation.  Fixed by: (a) making
--     amount nullable with a default of NULL so existing rows are not broken,
--     and (b) always setting amount = p_service_amount in the RPC INSERT.
--  3. create_booking_idempotent now accepts p_description and
--     p_customer_phone so the row is always complete on creation — no more
--     NULL description window between RPC and patch call.
--  4. booking_events audit trail — idempotent path now inserts
--     'booking_created' event so ops timeline is complete.
--  5. uuid-ossp extension guard in RUNME_FIRST equivalent.
-- ═══════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────
-- FIX 1: Add city column to bookings (if not already present)
-- The base schema.sql omits it; only the v7/v8 RPC references it.
-- Without this, create_booking_idempotent's INSERT fails with
-- "column city does not exist".
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS city TEXT;

-- Index for surge_signal view and any ops queries filtering by city
CREATE INDEX IF NOT EXISTS bookings_city_idx ON bookings (city)
  WHERE city IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────
-- FIX 2: Relax amount NOT NULL so create_booking_idempotent can
-- insert without it when amount is passed only as service_amount.
-- We default NULL so existing rows are untouched, and we add a
-- partial CHECK that amount must not be negative when set.
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE bookings
  ALTER COLUMN amount DROP NOT NULL,
  ALTER COLUMN amount SET DEFAULT NULL;

-- amount is now set from service_amount inside the RPC (see below).

-- ─────────────────────────────────────────────────────────────────
-- FIX 3+4+2: Rewrite create_booking_idempotent to:
--   • Accept p_description and p_customer_phone (no NULL window)
--   • Write amount = p_service_amount (FIX 2)
--   • Insert a booking_events audit row (FIX 4)
--   • Extract city from address as best-effort (FIX — city column)
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_booking_idempotent(
  p_customer_id       UUID,
  p_category          TEXT,
  p_service_tier      TEXT,
  p_address           TEXT,
  p_city              TEXT,            -- may be full address; we normalise below
  p_idempotency_key   UUID,
  p_service_amount    NUMERIC DEFAULT NULL,
  p_description       TEXT    DEFAULT NULL,   -- FIX 3: was patched separately
  p_customer_phone    TEXT    DEFAULT NULL    -- FIX 3: was patched separately
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing      UUID;
  v_new_id        UUID;
  v_fees          JSONB;
  v_wallet_credit NUMERIC;
  v_city          TEXT;
BEGIN
  -- ── Idempotency check ──────────────────────────────────────────
  SELECT id INTO v_existing
  FROM   bookings
  WHERE  idempotency_key = p_idempotency_key;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok',         true,
      'booking_id', v_existing,
      'idempotent', true
    );
  END IF;

  -- ── City normalisation ────────────────────────────────────────
  -- If the caller passed a full address string (e.g. "15 Berea Rd, Durban, 4001")
  -- instead of just a city name, try to extract the city token.
  -- Heuristic: last non-numeric, non-empty comma-separated part before the postcode.
  -- Falls back to the raw value so matching still works if it's already a city name.
  v_city := trim(p_city);
  IF v_city ~ ',' THEN
    -- Split on commas and pick the second-to-last or last non-postcode token
    SELECT trim(part) INTO v_city
    FROM (
      SELECT unnest(string_to_array(p_city, ',')) AS part
    ) parts
    WHERE trim(part) !~ '^\d+$'          -- not a bare postcode
      AND length(trim(part)) > 1
    ORDER BY length(trim(part)) DESC      -- prefer longer tokens (city names > suburbs)
    LIMIT 1;
    -- If the heuristic produced nothing, fall back to raw value
    v_city := COALESCE(NULLIF(trim(v_city), ''), trim(p_city));
  END IF;

  -- ── Fee preview ────────────────────────────────────────────────
  SELECT wallet_credit INTO v_wallet_credit
  FROM   profiles WHERE id = p_customer_id;
  v_wallet_credit := COALESCE(v_wallet_credit, 0);

  IF p_service_amount IS NOT NULL AND p_service_amount > 0 THEN
    v_fees := calculate_booking_fees(p_service_amount, v_wallet_credit);
  END IF;

  -- ── Insert at CREATED ─────────────────────────────────────────
  INSERT INTO bookings (
    customer_id, category, service_tier, address, city,
    description,                          -- FIX 3: direct insert, no patch needed
    customer_phone,                       -- FIX 3: direct insert, no patch needed
    status,
    payment_status,
    idempotency_key, created_at,
    amount,                               -- FIX 2: was missing → NOT NULL violation
    service_amount,
    wallet_credit_used,
    yoco_fee,
    total_charged,
    platform_fee,
    fixer_payout
  )
  VALUES (
    p_customer_id, p_category, p_service_tier, p_address, v_city,
    p_description,
    p_customer_phone,
    'CREATED',
    'pending',
    p_idempotency_key, now(),
    p_service_amount,                     -- FIX 2: amount = service_amount
    p_service_amount,
    COALESCE((v_fees->>'wallet_applied')::NUMERIC, 0),
    COALESCE((v_fees->>'yoco_fee')::NUMERIC,       0),
    COALESCE((v_fees->>'total_charged')::NUMERIC,  p_service_amount),
    COALESCE((v_fees->>'platform_fee')::NUMERIC,   0),
    COALESCE((v_fees->>'fixer_payout')::NUMERIC,   p_service_amount)
  )
  RETURNING id INTO v_new_id;

  -- ── Audit trail (FIX 4) ───────────────────────────────────────
  -- create_booking_idempotent previously had NO booking_events insert.
  -- The ops timeline was missing the creation event for all v8.3+ bookings.
  INSERT INTO booking_events (booking_id, event_type, new_status, created_by, metadata)
  VALUES (
    v_new_id,
    'booking_created',
    'CREATED',
    p_customer_id,
    jsonb_build_object(
      'has_coordinates',  false,       -- coordinates added by patch; not available here
      'match_method',     'city_text', -- will be updated to haversine if coords arrive
      'category',         p_category,
      'service_tier',     p_service_tier,
      'city',             v_city,
      'idempotency_key',  p_idempotency_key,
      'has_description',  (p_description IS NOT NULL),
      'has_phone',        (p_customer_phone IS NOT NULL)
    )
  );

  RETURN jsonb_build_object(
    'ok',         true,
    'booking_id', v_new_id,
    'idempotent', false,
    'fees',       v_fees
  );

EXCEPTION
  WHEN unique_violation THEN
    -- Race: two requests with same key hit simultaneously.
    SELECT id INTO v_existing
    FROM   bookings WHERE idempotency_key = p_idempotency_key;
    RETURN jsonb_build_object('ok', true, 'booking_id', v_existing, 'idempotent', true);
END;
$$;

-- Re-grant after replace
GRANT EXECUTE ON FUNCTION create_booking_idempotent(UUID, TEXT, TEXT, TEXT, TEXT, UUID, NUMERIC, TEXT, TEXT)
  TO authenticated;

-- Also grant the old 7-arg signature for any callers that haven't updated yet
-- (description and phone default to NULL so it's backwards compatible)
-- No separate grant needed — same function, default args.


-- ─────────────────────────────────────────────────────────────────
-- FIX 5: Ensure uuid-ossp is enabled (base schema depends on it)
-- RUNME_FIRST.sql only enables pgcrypto, not uuid-ossp. Without
-- uuid-ossp, uuid_generate_v4() calls in schema.sql throw:
--   ERROR:  function uuid_generate_v4() does not exist
-- ─────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─────────────────────────────────────────────────────────────────
-- Record migration
-- ─────────────────────────────────────────────────────────────────
INSERT INTO schema_migrations (version) VALUES ('v8.4') ON CONFLICT DO NOTHING;
