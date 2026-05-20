-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8.2 — YOCO TRANSACTION FEE TRACKING
-- Run AFTER 08_critical_fixes.sql.
-- Idempotent — safe to re-run.
--
-- Yoco SA fee: 2.95% flat per transaction (VAT inclusive).
-- No fixed per-transaction component on the standard Yoco Go/Plus plan.
-- Source: https://www.yoco.com/za/pricing/ (verified May 2025)
--
-- Design decisions (startup with no capital):
--   • The fee is ADDED TO the customer total, not absorbed by Servit.
--     This is the only viable model at zero margin — absorbing 2.95%
--     on every booking would eat your commission immediately.
--   • The fee is calculated server-side and stored on the booking row
--     so it's auditable and can be reconciled against Yoco statements.
--   • The RPC returns a full itemised breakdown for the UI to render.
--   • Wallet credit is applied BEFORE the Yoco fee is calculated —
--     the fee is only on the cash the customer actually pays.
--
-- FIX 3 (rate-lock): platform_fee and fixer_payout are stamped at
-- booking creation using the rate in effect at that moment, and stored
-- on the booking row. The after_booking_completed trigger respects these
-- stored values and only fills them if they are NULL (i.e. pre-v8.2
-- bookings that were created before the fee columns existed). This means
-- fixers are always paid what they were quoted, regardless of future
-- commission rate changes.
-- ═══════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────
-- 1. Add fee columns to bookings
-- ────────────────────────────────────────────────────────────────

ALTER TABLE bookings
  -- What the customer agreed to pay for the service (fixer quote)
  ADD COLUMN IF NOT EXISTS service_amount      NUMERIC(10,2),

  -- Wallet credit applied at checkout (mirrors wallet_transactions debit)
  ADD COLUMN IF NOT EXISTS wallet_credit_used  NUMERIC(10,2) NOT NULL DEFAULT 0,

  -- Yoco processing fee (2.95% of the cash paid after wallet credit)
  ADD COLUMN IF NOT EXISTS yoco_fee            NUMERIC(10,2) NOT NULL DEFAULT 0,

  -- What the customer was actually charged at the payment gateway
  ADD COLUMN IF NOT EXISTS total_charged       NUMERIC(10,2),

  -- Servit's platform commission (your cut — stored separately from fixer's)
  -- commission column already exists from base schema; this adds platform_fee
  ADD COLUMN IF NOT EXISTS platform_fee        NUMERIC(10,2),

  -- What the fixer gets paid out (service_amount - platform_fee)
  ADD COLUMN IF NOT EXISTS fixer_payout        NUMERIC(10,2);

-- ────────────────────────────────────────────────────────────────
-- 2. Yoco fee constants (stored as DB settings so you can update
--    them in one place if Yoco changes their pricing)
-- ────────────────────────────────────────────────────────────────

-- Store as a JSONB config row — zero extra infrastructure
CREATE TABLE IF NOT EXISTS platform_config (
  key         TEXT PRIMARY KEY,
  value       JSONB NOT NULL,
  updated_at  TIMESTAMPTZ DEFAULT now(),
  note        TEXT
);

-- Seed Yoco fee config (safe to re-run — ON CONFLICT DO NOTHING)
INSERT INTO platform_config (key, value, note) VALUES
  ('yoco_fee_rate',
   '{"rate": 0.0295, "label": "Yoco processing fee (2.95%)", "vat_inclusive": true}',
   'Yoco Go/Plus flat rate. Update here if Yoco changes pricing. Source: yoco.com/za/pricing')
ON CONFLICT (key) DO NOTHING;

-- Servit platform commission rate (your cut of the service amount)
INSERT INTO platform_config (key, value, note) VALUES
  ('platform_commission_rate',
   '{"rate": 0.12, "label": "Servit platform fee (12%)"}',
   'Your commission on each completed booking. Update here to change globally.')
ON CONFLICT (key) DO NOTHING;

GRANT SELECT ON platform_config TO authenticated;
GRANT ALL    ON platform_config TO service_role;


-- ────────────────────────────────────────────────────────────────
-- 3. Core fee calculation function
-- Returns a full itemised breakdown given a service amount and
-- any wallet credit the customer is applying.
-- Called from both the UI (booking summary) and at checkout.
-- ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION calculate_booking_fees(
  p_service_amount   NUMERIC,   -- what the fixer quoted
  p_wallet_credit    NUMERIC DEFAULT 0  -- how much wallet credit to apply
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_yoco_rate         NUMERIC;
  v_platform_rate     NUMERIC;
  v_wallet_applied    NUMERIC;
  v_cash_before_fee   NUMERIC;   -- amount customer pays in cash (after wallet)
  v_yoco_fee          NUMERIC;
  v_total_charged     NUMERIC;   -- cash_before_fee + yoco_fee (what hits Yoco)
  v_platform_fee      NUMERIC;
  v_fixer_payout      NUMERIC;
BEGIN
  -- Load rates from config
  SELECT (value->>'rate')::NUMERIC INTO v_yoco_rate
  FROM platform_config WHERE key = 'yoco_fee_rate';
  v_yoco_rate := COALESCE(v_yoco_rate, 0.0295);

  SELECT (value->>'rate')::NUMERIC INTO v_platform_rate
  FROM platform_config WHERE key = 'platform_commission_rate';
  v_platform_rate := COALESCE(v_platform_rate, 0.12);

  -- Wallet credit: can't exceed the service amount
  v_wallet_applied  := LEAST(COALESCE(p_wallet_credit, 0), p_service_amount);
  v_wallet_applied  := GREATEST(v_wallet_applied, 0);

  -- Cash the customer pays to Yoco (service amount minus wallet)
  v_cash_before_fee := p_service_amount - v_wallet_applied;

  -- Yoco fee: only on the cash portion (wallet credit doesn't go through Yoco)
  -- Round UP to the nearest cent — Yoco charges you the ceiling, not the floor
  v_yoco_fee := CASE
    WHEN v_cash_before_fee <= 0 THEN 0
    ELSE CEILING(v_cash_before_fee * v_yoco_rate * 100) / 100
  END;

  -- Total the customer pays at the gateway
  v_total_charged := v_cash_before_fee + v_yoco_fee;

  -- Servit platform fee (on the full service amount, not on the Yoco fee)
  v_platform_fee  := ROUND(p_service_amount * v_platform_rate, 2);

  -- What the fixer gets after your commission
  v_fixer_payout  := ROUND(p_service_amount - v_platform_fee, 2);

  RETURN jsonb_build_object(
    -- Input
    'service_amount',    p_service_amount,
    'wallet_applied',    v_wallet_applied,

    -- Fee line items
    'yoco_fee',          v_yoco_fee,
    'yoco_rate_pct',     ROUND(v_yoco_rate * 100, 2),
    'platform_fee',      v_platform_fee,
    'platform_rate_pct', ROUND(v_platform_rate * 100, 0),

    -- What customer pays
    'cash_before_fee',   v_cash_before_fee,
    'total_charged',     v_total_charged,

    -- What fixer gets
    'fixer_payout',      v_fixer_payout,

    -- Human-readable lines for the booking summary UI
    'line_items', jsonb_build_array(
      jsonb_build_object('label', 'Service fee',           'amount', p_service_amount,    'type', 'service'),
      jsonb_build_object('label', '💰 Wallet credit',      'amount', -v_wallet_applied,   'type', 'credit',
                         'show', v_wallet_applied > 0),
      jsonb_build_object('label', 'Yoco processing (2.95%)', 'amount', v_yoco_fee,        'type', 'fee',
                         'note', 'Secure card payment fee'),
      jsonb_build_object('label', 'Total',                 'amount', v_total_charged,     'type', 'total')
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION calculate_booking_fees(NUMERIC, NUMERIC)
  TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────
-- 4. Updated create_booking_idempotent — stores fee breakdown
-- Replaces the version in 08_critical_fixes.sql.
-- Now accepts service_amount and computes + stores all fee columns.
-- ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION create_booking_idempotent(
  p_customer_id       UUID,
  p_category          TEXT,
  p_service_tier      TEXT,
  p_address           TEXT,
  p_city              TEXT,
  p_idempotency_key   UUID,
  p_service_amount    NUMERIC DEFAULT NULL  -- fixer's quoted price
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing   UUID;
  v_new_id     UUID;
  v_fees       JSONB;
  v_wallet_credit NUMERIC;
BEGIN
  -- Idempotency check
  SELECT id INTO v_existing
  FROM bookings WHERE idempotency_key = p_idempotency_key;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true, 'booking_id', v_existing, 'idempotent', true
    );
  END IF;

  -- Load customer's current wallet credit for fee preview
  SELECT wallet_credit INTO v_wallet_credit
  FROM profiles WHERE id = p_customer_id;
  v_wallet_credit := COALESCE(v_wallet_credit, 0);

  -- Calculate fees if amount provided
  IF p_service_amount IS NOT NULL AND p_service_amount > 0 THEN
    v_fees := calculate_booking_fees(p_service_amount, v_wallet_credit);
  END IF;

  INSERT INTO bookings (
    customer_id, category, service_tier, address, city, status,
    idempotency_key, created_at,
    service_amount,
    wallet_credit_used,
    yoco_fee,
    total_charged,
    platform_fee,
    fixer_payout
  )
  VALUES (
    p_customer_id, p_category, p_service_tier, p_address, p_city, 'SEARCHING',
    p_idempotency_key, now(),
    p_service_amount,
    COALESCE((v_fees->>'wallet_applied')::NUMERIC, 0),
    COALESCE((v_fees->>'yoco_fee')::NUMERIC, 0),
    COALESCE((v_fees->>'total_charged')::NUMERIC, p_service_amount),
    COALESCE((v_fees->>'platform_fee')::NUMERIC, 0),
    COALESCE((v_fees->>'fixer_payout')::NUMERIC, p_service_amount)
  )
  RETURNING id INTO v_new_id;

  RETURN jsonb_build_object(
    'ok',           true,
    'booking_id',   v_new_id,
    'idempotent',   false,
    'fees',         v_fees   -- return to client so UI can display breakdown immediately
  );

EXCEPTION
  WHEN unique_violation THEN
    SELECT id INTO v_existing FROM bookings WHERE idempotency_key = p_idempotency_key;
    RETURN jsonb_build_object('ok', true, 'booking_id', v_existing, 'idempotent', true);
END;
$$;

GRANT EXECUTE ON FUNCTION create_booking_idempotent(UUID, TEXT, TEXT, TEXT, TEXT, UUID, NUMERIC)
  TO authenticated;


-- ────────────────────────────────────────────────────────────────
-- 5. Updated apply_wallet_credit_to_booking
-- Now recalculates the Yoco fee after credit is applied and
-- updates the stored fee columns on the booking row.
-- ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION apply_wallet_credit_to_booking(
  p_customer_id    UUID,
  p_booking_id     UUID,
  p_booking_amount NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available_credit  NUMERIC;
  v_fees              JSONB;
BEGIN
  SELECT wallet_credit INTO v_available_credit
  FROM profiles WHERE id = p_customer_id
  FOR UPDATE;

  v_available_credit := COALESCE(v_available_credit, 0);

  -- Recalculate fees with wallet credit applied
  v_fees := calculate_booking_fees(p_booking_amount, v_available_credit);

  IF v_available_credit <= 0 THEN
    -- No credit — still update the fee columns on the booking
    UPDATE bookings SET
      service_amount     = p_booking_amount,
      wallet_credit_used = 0,
      yoco_fee           = (v_fees->>'yoco_fee')::NUMERIC,
      total_charged      = (v_fees->>'total_charged')::NUMERIC
    WHERE id = p_booking_id;

    RETURN v_fees || jsonb_build_object('ok', true, 'wallet_after', 0);
  END IF;

  -- Deduct wallet credit
  UPDATE profiles
  SET wallet_credit = wallet_credit - (v_fees->>'wallet_applied')::NUMERIC
  WHERE id = p_customer_id;

  -- Log debit
  INSERT INTO wallet_transactions (user_id, amount, reason, related_id)
  VALUES (
    p_customer_id,
    -(v_fees->>'wallet_applied')::NUMERIC,
    'booking_credit_applied',
    p_booking_id
  );

  -- Stamp all fee columns on the booking row
  UPDATE bookings SET
    service_amount     = p_booking_amount,
    wallet_credit_used = (v_fees->>'wallet_applied')::NUMERIC,
    yoco_fee           = (v_fees->>'yoco_fee')::NUMERIC,
    total_charged      = (v_fees->>'total_charged')::NUMERIC
  WHERE id = p_booking_id;

  RETURN v_fees || jsonb_build_object(
    'ok',          true,
    'wallet_after', v_available_credit - (v_fees->>'wallet_applied')::NUMERIC
  );
END;
$$;

GRANT EXECUTE ON FUNCTION apply_wallet_credit_to_booking(UUID, UUID, NUMERIC)
  TO authenticated;


-- ────────────────────────────────────────────────────────────────
-- 6. Mark fee columns on completed bookings (for reconciliation)
-- After a booking completes, stamp platform_fee and fixer_payout.
-- Add to the after_booking_completed trigger in 06_production_hardening.sql.
-- ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION after_booking_completed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_platform_rate NUMERIC;
BEGIN
  IF NEW.status != 'COMPLETED' OR OLD.status = 'COMPLETED' THEN
    RETURN NEW;
  END IF;

  -- FIX 3 (rate-lock): platform_fee and fixer_payout are stamped at booking
  -- creation time (by create_booking_idempotent / calculate_booking_fees) using
  -- the commission rate in effect when the customer booked. We ONLY back-fill here
  -- for pre-v8.2 rows where the columns are NULL — we never overwrite a stored value.
  -- This ensures fixers are always paid what was quoted, regardless of future rate changes.
  IF NEW.platform_fee IS NULL OR NEW.fixer_payout IS NULL THEN
    SELECT (value->>'rate')::NUMERIC INTO v_platform_rate
    FROM platform_config WHERE key = 'platform_commission_rate';
    v_platform_rate := COALESCE(v_platform_rate, 0.12);

    UPDATE bookings SET
      platform_fee  = ROUND(COALESCE(service_amount, 0) * v_platform_rate, 2),
      fixer_payout  = ROUND(COALESCE(service_amount, 0) * (1 - v_platform_rate), 2)
    WHERE id = NEW.id
      AND (platform_fee IS NULL OR fixer_payout IS NULL);
  END IF;

  -- Customer profile stats
  UPDATE profiles SET
    total_bookings  = total_bookings + 1,
    last_booking_at = now(),
    last_category   = COALESCE(NEW.category, last_category),
    last_fixer_id   = COALESCE(NEW.fixer_id, last_fixer_id),
    last_fixer_name = COALESCE(
      (SELECT full_name FROM fixers WHERE id = NEW.fixer_id),
      last_fixer_name
    )
  WHERE id = NEW.customer_id;

  -- Fixer stats: use the locked fixer_payout for total_earnings if available,
  -- otherwise fall back to commission column (pre-v8.2 rows)
  IF NEW.fixer_id IS NOT NULL THEN
    UPDATE fixers SET
      total_completed = COALESCE(total_completed, 0) + 1,
      total_earnings  = COALESCE(total_earnings, 0) +
                        COALESCE(NEW.fixer_payout, NEW.commission, 0),
      first_job_at    = COALESCE(first_job_at, now()),
      last_online_at  = now()
    WHERE id = NEW.fixer_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_after_booking_completed ON bookings;
CREATE TRIGGER trg_after_booking_completed
  AFTER UPDATE ON bookings
  FOR EACH ROW EXECUTE FUNCTION after_booking_completed();


-- ────────────────────────────────────────────────────────────────
-- 7. Revenue view for admin dashboard
-- ────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW revenue_summary AS
SELECT
  date_trunc('day', created_at)::DATE               AS day,
  COUNT(*) FILTER (WHERE status = 'COMPLETED')       AS completed_bookings,
  SUM(service_amount)  FILTER (WHERE status = 'COMPLETED')  AS gross_service_value,
  SUM(yoco_fee)        FILTER (WHERE status = 'COMPLETED')  AS total_yoco_fees_paid,
  SUM(platform_fee)    FILTER (WHERE status = 'COMPLETED')  AS servit_revenue,
  SUM(fixer_payout)    FILTER (WHERE status = 'COMPLETED')  AS total_fixer_payouts,
  SUM(wallet_credit_used) FILTER (WHERE status = 'COMPLETED') AS wallet_credits_redeemed,
  -- Net Servit cash (revenue minus credits you funded, plus Yoco fee passed through)
  SUM(platform_fee) FILTER (WHERE status = 'COMPLETED') -
  SUM(wallet_credit_used) FILTER (WHERE status = 'COMPLETED')  AS net_servit_cash
FROM bookings
GROUP BY 1
ORDER BY 1 DESC;

GRANT SELECT ON revenue_summary TO service_role;


-- ────────────────────────────────────────────────────────────────
-- VERIFICATION
-- ────────────────────────────────────────────────────────────────
/*
-- 1. Test fee calculator
SELECT calculate_booking_fees(500.00, 50.00);
-- Expected: service=500, wallet_applied=50, cash_before_fee=450,
--           yoco_fee=ceil(450*0.0295)=13.28 (rounds up),
--           total_charged=463.28

-- 2. Test zero wallet credit
SELECT calculate_booking_fees(800.00, 0);
-- yoco_fee = ceil(800 * 0.0295) = ceil(23.60) = 23.60, total = 823.60

-- 3. Full wallet cover
SELECT calculate_booking_fees(100.00, 200.00);
-- wallet_applied=100 (capped at service amount), cash_before_fee=0,
-- yoco_fee=0 (no cash goes through Yoco), total_charged=0

-- 4. Confirm columns on bookings
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'bookings'
  AND column_name IN ('service_amount','wallet_credit_used','yoco_fee','total_charged','platform_fee','fixer_payout');

-- 5. Check platform_config seeded
SELECT key, value FROM platform_config;

-- 6. Update Yoco rate if they change pricing (run once):
-- UPDATE platform_config SET value = '{"rate": 0.029, "label": "Yoco processing fee (2.9%)", "vat_inclusive": true}', updated_at = now() WHERE key = 'yoco_fee_rate';
*/


-- ────────────────────────────────────────────────────────────────
-- 8. Updated get_fixer_earnings_statement
-- FIX 5: v8.1 version used b.commission (the old column, which held
-- the raw service amount before Servit's cut). Now that fixer_payout
-- (service_amount - platform_fee) is stored on every booking from v8.2
-- onwards, we use it directly. For pre-v8.2 rows where fixer_payout is
-- NULL, we fall back to commission so old jobs still appear correctly.
-- The UI label clearly shows "Your earnings (after Servit fee)" so
-- fixers are never confused about why the number differs from the
-- quoted job price.
-- Replaces the version in 08_critical_fixes.sql.
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
  IF auth.uid() != (SELECT user_id FROM fixers WHERE id = p_fixer_id) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  SELECT jsonb_build_object(
    'fixer_id',        p_fixer_id,
    'period_days',     p_days,
    'generated_at',    now(),
    -- FIX 5: use fixer_payout (net of Servit commission) for v8.2+ rows,
    -- fall back to commission column for pre-v8.2 rows where fixer_payout is NULL.
    'total_period',    COALESCE(SUM(
                         COALESCE(b.fixer_payout, b.commission, 0)
                       ) FILTER (
                         WHERE b.status = 'COMPLETED'
                         AND b.created_at >= now() - (p_days || ' days')::INTERVAL
                       ), 0),
    'total_all_time',  f.total_earnings,
    -- Rate metadata so the UI can show "Servit fee: 10%" clearly
    'commission_rate_pct', (
      SELECT ROUND((value->>'rate')::NUMERIC * 100, 0)
      FROM platform_config WHERE key = 'platform_commission_rate'
    ),
    'jobs', (
      SELECT jsonb_agg(
        jsonb_build_object(
          'booking_id',    b2.id,
          'completed_at',  b2.completed_at,
          'category',      b2.category,
          'service_tier',  b2.service_tier,
          'customer_city', b2.city,
          -- Gross price the customer paid for the service
          'service_amount', b2.service_amount,
          -- Servit's cut (shown so fixers can verify the maths)
          'platform_fee',  b2.platform_fee,
          -- Net amount the fixer earns. For pre-v8.2 rows fixer_payout
          -- is NULL so we fall back to commission.
          'amount_earned', COALESCE(b2.fixer_payout, b2.commission, 0),
          -- Flag pre-v8.2 rows so UI can show a note if desired
          'is_legacy_row', (b2.fixer_payout IS NULL),
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
    'jobs',        '[]'::JSONB
  ));
END;
$$;

GRANT EXECUTE ON FUNCTION get_fixer_earnings_statement(UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_fixer_earnings_statement(UUID, INTEGER) TO service_role;
