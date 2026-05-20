-- v8.7 assignment safety hotfix
-- 1) Enables SEARCHING -> EXPIRED transitions for no-fixer timeout flow.
-- 2) Adds expire_booking_no_fixer() helper for server-side timeout processing.

CREATE OR REPLACE FUNCTION validate_booking_transition(
  old_status booking_status_enum,
  new_status booking_status_enum
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN (
    (old_status = 'CREATED'             AND new_status = 'PENDING_PAYMENT') OR
    (old_status = 'PENDING_PAYMENT'     AND new_status = 'SEARCHING') OR
    (old_status = 'SEARCHING'           AND new_status = 'OFFERED') OR
    (old_status = 'SEARCHING'           AND new_status = 'EXPIRED') OR
    (old_status = 'OFFERED'             AND new_status = 'CONFIRMED') OR
    (old_status = 'OFFERED'             AND new_status = 'SEARCHING') OR
    (old_status = 'CONFIRMED'           AND new_status = 'EN_ROUTE') OR
    (old_status = 'EN_ROUTE'            AND new_status = 'ARRIVED') OR
    (old_status = 'ARRIVED'             AND new_status = 'IN_PROGRESS') OR
    (old_status = 'IN_PROGRESS'         AND new_status = 'PENDING_COMPLETION') OR
    (old_status = 'PENDING_COMPLETION'  AND new_status = 'COMPLETED') OR
    (old_status = 'CONFIRMED'           AND new_status = 'DISPUTED') OR
    (old_status = 'IN_PROGRESS'         AND new_status = 'DISPUTED') OR
    (old_status = 'PENDING_COMPLETION'  AND new_status = 'DISPUTED') OR
    (old_status = 'DISPUTED'            AND new_status = 'COMPLETED') OR
    (old_status = 'DISPUTED'            AND new_status = 'CANCELLED') OR
    (old_status = 'PENDING_PAYMENT'     AND new_status = 'CANCELLED') OR
    (old_status = 'PENDING_PAYMENT'     AND new_status = 'EXPIRED') OR
    (old_status = 'SEARCHING'           AND new_status = 'CANCELLED') OR
    (old_status = 'OFFERED'             AND new_status = 'CANCELLED') OR
    (old_status = 'OFFERED'             AND new_status = 'EXPIRED') OR
    (old_status = 'CONFIRMED'           AND new_status = 'CANCELLED') OR
    (old_status = 'EN_ROUTE'            AND new_status = 'CANCELLED') OR
    (old_status = 'ARRIVED'             AND new_status = 'CANCELLED')
  );
END;
$$;

CREATE OR REPLACE FUNCTION expire_booking_no_fixer(
  p_booking_id UUID,
  p_reason TEXT DEFAULT 'no_fixer_timeout'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking bookings%ROWTYPE;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT * INTO v_booking
  FROM bookings
  WHERE id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;

  IF v_booking.status NOT IN ('SEARCHING', 'OFFERED') THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'status_not_eligible',
      'status', v_booking.status
    );
  END IF;

  IF v_booking.payment_status <> 'paid' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'payment_not_paid',
      'status', v_booking.status
    );
  END IF;

  UPDATE bookings
  SET
    status = 'EXPIRED',
    updated_at = now(),
    version = version + 1
  WHERE id = p_booking_id;

  INSERT INTO booking_events (
    booking_id,
    event_type,
    old_status,
    new_status,
    metadata
  ) VALUES (
    p_booking_id,
    'no_fixer_found',
    v_booking.status,
    'EXPIRED',
    jsonb_build_object('reason', p_reason)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'booking_id', p_booking_id,
    'old_status', v_booking.status,
    'new_status', 'EXPIRED'
  );
END;
$$;

CREATE OR REPLACE FUNCTION reset_booking_to_searching(
  p_booking_id UUID,
  p_actor_user_id UUID,
  p_reason TEXT DEFAULT 'manual_retry',
  p_booking_mode booking_mode_enum DEFAULT NULL,
  p_scheduled_for TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking bookings%ROWTYPE;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT * INTO v_booking
  FROM bookings
  WHERE id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;

  IF v_booking.payment_status <> 'paid' THEN
    RAISE EXCEPTION 'Booking is not paid';
  END IF;

  IF v_booking.status NOT IN ('SEARCHING', 'OFFERED') THEN
    RAISE EXCEPTION 'Booking not eligible for search reset';
  END IF;

  UPDATE bookings
  SET
    status = 'SEARCHING',
    current_offer_id = NULL,
    offer_expires_at = NULL,
    booking_mode = COALESCE(p_booking_mode, booking_mode),
    scheduled_for = CASE WHEN p_scheduled_for IS NOT NULL THEN p_scheduled_for ELSE scheduled_for END,
    updated_at = now(),
    version = version + 1
  WHERE id = p_booking_id;

  INSERT INTO booking_events (
    booking_id, event_type, old_status, new_status, created_by, metadata
  ) VALUES (
    p_booking_id,
    'search_reset',
    v_booking.status,
    'SEARCHING',
    p_actor_user_id,
    jsonb_build_object(
      'reason', p_reason,
      'booking_mode', COALESCE(p_booking_mode::text, v_booking.booking_mode::text),
      'scheduled_for', p_scheduled_for
    )
  );

  RETURN jsonb_build_object('ok', true, 'booking_id', p_booking_id, 'old_status', v_booking.status, 'new_status', 'SEARCHING');
END;
$$;

-- ═══════════════════════════════════════════════════════════════
-- v8.7 addendum: refund-fail guard & assignment-fail safety
-- Added by Payment-to-Assignment Stabilisation Plan
-- ═══════════════════════════════════════════════════════════════

-- ensure_refund_on_expire
-- Safety net: called by the timeout cron AFTER expire_booking_no_fixer().
-- If mark_payment_refunded was already called (Yoco succeeded), this is a
-- no-op. If refund hasn't landed yet (e.g. Yoco call failed in Node but
-- the booking was already EXPIRED), it surfaces the gap so it can be retried.
CREATE OR REPLACE FUNCTION ensure_refund_on_expire(
  p_booking_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payment payments%ROWTYPE;
BEGIN
  SELECT * INTO v_payment
  FROM payments
  WHERE booking_id = p_booking_id
    AND status     = 'paid'           -- still paid means refund hasn't landed
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    -- Either already refunded or no paid payment exists — nothing to do.
    RETURN jsonb_build_object('ok', true, 'action', 'noop');
  END IF;

  -- Insert a sentinel event so the admin can see refund is outstanding.
  -- Does NOT mark it as refunded — the Node cron or manual retry must call
  -- mark_payment_refunded once Yoco actually processes it.
  INSERT INTO booking_events (
    booking_id, event_type, old_status, new_status, metadata
  )
  SELECT
    p_booking_id,
    'refund_pending',
    NULL,
    NULL,
    jsonb_build_object(
      'payment_id',             v_payment.id,
      'provider_payment_id',    v_payment.provider_payment_id,
      'amount',                 v_payment.amount
    )
  WHERE NOT EXISTS (
    -- Idempotent: only insert if no refund event exists yet
    SELECT 1 FROM booking_events be
    WHERE  be.booking_id  = p_booking_id
      AND  be.event_type IN ('payment_refunded', 'refund_pending', 'refund_failed')
  );

  RETURN jsonb_build_object(
    'ok',        true,
    'action',    'refund_pending_flagged',
    'payment_id', v_payment.id
  );
END;
$$;

-- expire_and_ensure_refund
-- Convenience wrapper: expires the booking AND flags any outstanding refund
-- in a single RPC call. Replaces the two-step pattern in the Node cron.
CREATE OR REPLACE FUNCTION expire_and_ensure_refund(
  p_booking_id UUID,
  p_reason     TEXT DEFAULT 'no_fixer_timeout'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expire JSONB;
  v_refund JSONB;
BEGIN
  SELECT expire_booking_no_fixer(p_booking_id, p_reason) INTO v_expire;

  IF NOT (v_expire->>'ok')::boolean THEN
    RETURN v_expire;
  END IF;

  SELECT ensure_refund_on_expire(p_booking_id) INTO v_refund;

  RETURN jsonb_build_object(
    'ok',          true,
    'expire',      v_expire,
    'refund_flag', v_refund
  );
END;
$$;
