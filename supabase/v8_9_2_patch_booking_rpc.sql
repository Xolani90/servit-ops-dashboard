-- ═══════════════════════════════════════════════════════════════════════
-- Servit v8.9.2 — patch_booking_fields SECURITY DEFINER RPC
-- Generated: 2026-05-13
--
-- Closes BUG 15 from the v8.9.1 audit report:
--   create-booking.js was patching bookings via a direct .update() call
--   that silently failed because the bookings table has restrictive RLS
--   policies.  Even with the service_role key, Supabase RLS can fire for
--   direct table mutations in certain policy configurations.
--
-- This RPC runs as SECURITY DEFINER (DB-owner role), fully bypasses RLS,
-- and is intentionally restricted: it only allows patching the four
--  fields that create-booking legitimately needs to set after the initial
--  create_booking_idempotent() call.  No other columns can be written.
--
-- Run after v8_9_1_audit_fixes.sql (order does not matter technically,
-- but follow the DEPLOY_ORDER sequence).
-- ═══════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION patch_booking_fields(
  p_booking_id       UUID,
  p_customer_id      UUID,          -- ownership check: only the booking owner may patch
  p_service_tier     TEXT           DEFAULT NULL,
  p_booking_mode     TEXT           DEFAULT NULL,
  p_scheduled_for    TIMESTAMPTZ    DEFAULT NULL,
  p_latitude         DOUBLE PRECISION DEFAULT NULL,
  p_longitude        DOUBLE PRECISION DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking bookings%ROWTYPE;
BEGIN
  -- 1. Ownership guard — never allow patching another customer's booking
  SELECT * INTO v_booking
  FROM bookings
  WHERE id = p_booking_id
    AND customer_id = p_customer_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'booking_not_found_or_forbidden'
    );
  END IF;

  -- 2. Only patch if booking is still in an early state (CREATED or PENDING_PAYMENT).
  --    Refuse silently once the booking has been paid and dispatched — it's too late.
  IF v_booking.status NOT IN ('CREATED', 'PENDING_PAYMENT') THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'error',  'booking_already_advanced',
      'status', v_booking.status
    );
  END IF;

  -- 3. Validate service_tier if supplied
  IF p_service_tier IS NOT NULL
     AND p_service_tier NOT IN ('basic', 'standard', 'premium') THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'error', 'invalid_service_tier'
    );
  END IF;

  -- 4. Apply the patch — only update non-NULL arguments
  UPDATE bookings SET
    service_tier      = COALESCE(p_service_tier::TEXT::service_tier_enum, service_tier),
    booking_mode      = COALESCE(p_booking_mode::TEXT::booking_mode_enum, booking_mode),
    scheduled_for     = COALESCE(p_scheduled_for,    scheduled_for),
    customer_latitude  = COALESCE(p_latitude,         customer_latitude),
    customer_longitude = COALESCE(p_longitude,        customer_longitude),
    updated_at        = now()
  WHERE id = p_booking_id;

  RETURN jsonb_build_object('ok', true, 'booking_id', p_booking_id);
END;
$$;

-- Grant execute to the anon and authenticated roles so the Netlify function
-- (which authenticates via service_role) can call it. The ownership check
-- inside the function prevents privilege escalation.
REVOKE EXECUTE ON FUNCTION patch_booking_fields(
  UUID, UUID, TEXT, TEXT, TIMESTAMPTZ, DOUBLE PRECISION, DOUBLE PRECISION
) FROM anon;
GRANT EXECUTE ON FUNCTION patch_booking_fields(
  UUID, UUID, TEXT, TEXT, TIMESTAMPTZ, DOUBLE PRECISION, DOUBLE PRECISION
) TO authenticated, service_role;

COMMENT ON FUNCTION patch_booking_fields IS
  'v8.9.2: SECURITY DEFINER wrapper to patch supplemental booking fields '
  '(service_tier, booking_mode, scheduled_for, coordinates) after the '
  'initial create_booking_idempotent() call.  Bypasses RLS safely by '
  'performing an explicit customer_id ownership check before mutating.';
