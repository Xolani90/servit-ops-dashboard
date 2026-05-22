-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8.9.9 — 15% COMMISSION UPDATE
-- Run AFTER v7 migrations are deployed.
-- Idempotent — safe to re-run.
--
-- Changes:
--   • Platform commission rate increased from 12% to 15%
--   • Added p_service_type parameter to calculate_booking_fees
--   • Venue bookings: customer pays service + platform fee, fixer gets full amount
--   • Mobile bookings: customer pays service, fixer gets service - platform fee
-- ═══════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────
-- 1. Update platform commission rate to 15%
-- ────────────────────────────────────────────────────────────────

UPDATE platform_config
SET value = '{"rate": 0.15, "label": "Servit platform fee (15%)"}',
    updated_at = now()
WHERE key = 'platform_commission_rate';

-- ────────────────────────────────────────────────────────────────
-- 2. DROP and CREATE OR REPLACE calculate_booking_fees with new logic
-- ────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS calculate_booking_fees(NUMERIC, NUMERIC);

CREATE OR REPLACE FUNCTION calculate_booking_fees(
  p_service_amount   NUMERIC,   -- what the fixer quoted
  p_wallet_credit    NUMERIC DEFAULT 0,  -- how much wallet credit to apply
  p_service_type     TEXT DEFAULT 'mobile'  -- 'mobile' | 'venue'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_platform_rate     NUMERIC;
  v_wallet_applied    NUMERIC;
  v_cash_before_fee   NUMERIC;   -- amount customer pays in cash (after wallet)
  v_platform_fee      NUMERIC;
  v_fixer_payout      NUMERIC;
  v_total_charged     NUMERIC;
  v_is_venue          BOOLEAN;
BEGIN
  -- Load platform rate from config
  SELECT (value->>'rate')::NUMERIC INTO v_platform_rate
  FROM platform_config WHERE key = 'platform_commission_rate';
  v_platform_rate := COALESCE(v_platform_rate, 0.15);

  -- Determine service type
  v_is_venue := (p_service_type = 'venue');

  -- Wallet credit: can't exceed the service amount
  v_wallet_applied  := LEAST(COALESCE(p_wallet_credit, 0), p_service_amount);
  v_wallet_applied  := GREATEST(v_wallet_applied, 0);

  -- Cash the customer pays (service amount minus wallet)
  v_cash_before_fee := p_service_amount - v_wallet_applied;

  -- Platform fee (15%, min R15)
  v_platform_fee := GREATEST(ROUND(p_service_amount * v_platform_rate, 2), 15);

  -- MOBILE: customer pays service amount, fixer receives amount - platformFee
  -- VENUE: customer pays service amount + platformFee, fixer receives full amount
  IF v_is_venue THEN
    v_fixer_payout := p_service_amount;
    v_total_charged := p_service_amount + v_platform_fee;
  ELSE
    v_fixer_payout := p_service_amount - v_platform_fee;
    v_total_charged := p_service_amount;
  END IF;

  RETURN jsonb_build_object(
    -- Input
    'service_amount',    p_service_amount,
    'wallet_applied',    v_wallet_applied,
    'service_type',      p_service_type,

    -- Fee line items
    'platform_fee',      v_platform_fee,
    'platform_rate_pct', ROUND(v_platform_rate * 100, 0),

    -- What customer pays
    'cash_before_fee',   v_cash_before_fee,
    'total_charged',     v_total_charged,

    -- What fixer gets
    'fixer_payout',      v_fixer_payout,

    -- Human-readable lines for the booking summary UI
    'line_items', jsonb_build_array(
      CASE WHEN v_is_venue THEN
        jsonb_build_object('label', 'Service price', 'amount', p_service_amount, 'type', 'service')
      ELSE
        jsonb_build_object('label', 'Service fee', 'amount', p_service_amount, 'type', 'service')
      END,
      jsonb_build_object('label', 'Platform fee (15%)', 'amount', v_platform_fee, 'type', 'fee'),
      jsonb_build_object('label', '💰 Wallet credit', 'amount', -v_wallet_applied, 'type', 'credit',
                         'show', v_wallet_applied > 0),
      jsonb_build_object('label', 'Total', 'amount', v_total_charged, 'type', 'total')
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION calculate_booking_fees(NUMERIC, NUMERIC, TEXT)
  TO authenticated, service_role;
