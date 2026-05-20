-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8.9 — Payment Flow & Fixer Search Fixes
-- Run AFTER v8_8_cron_fixes.sql
-- Idempotent — safe to re-run.
--
-- Bugs fixed in this file:
--
--  BUG 1 (CRITICAL — venue bookings silently broken)
--    process_yoco_payment_success used ABS(expected - actual) > 0.01
--    which threw an exception for every venue booking because Yoco
--    charges the full blended amount (service + platform fee + Yoco fee)
--    while payments.amount stores only the quoted service_amount.
--    Effect: webhook handler crashed, booking never advanced from
--    PENDING_PAYMENT to SEARCHING, customer money taken with no fixer.
--    FIX: Only reject underpayment (p_amount < stored - 0.01). Accept
--    overpayment. Store actual captured amount for reconciliation.
--
--  BUG 2 (CRITICAL — reopen-after-payment sends user to home screen)
--    resumeActiveBookingIfAny() queried for PENDING_PAYMENT bookings
--    with payment_status = 'paid'. But payment_status is still 'pending'
--    until the Yoco webhook fires — there is a race window of 2-30s
--    after redirect where payment_status is not yet 'paid'. Any user
--    who reopened the app in that window got silently routed to the
--    home screen with their money taken.
--    FIX: Schema-side — add index to support the OR query used in the
--    frontend fix that covers both paid AND recently-created bookings.
-- ═══════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────
-- SECTION 1 — Add amount_captured column to payments
-- ─────────────────────────────────────────────────────────────────

ALTER TABLE payments
  ADD COLUMN IF NOT EXISTS amount_captured NUMERIC;

COMMENT ON COLUMN payments.amount_captured IS
  'Actual amount charged by Yoco (may exceed service_amount for venue service type where fees are added on top)';

-- ─────────────────────────────────────────────────────────────────
-- SECTION 2 — Replace process_yoco_payment_success
--             (idempotent CREATE OR REPLACE)
-- ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION process_yoco_payment_success(
  p_payment_id          UUID,
  p_provider_payment_id TEXT,
  p_amount              NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking bookings%ROWTYPE;
  v_payment payments%ROWTYPE;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  -- Get payment record with lock
  SELECT * INTO v_payment FROM payments WHERE id = p_payment_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment not found: %', p_payment_id;
  END IF;

  -- Prevent double processing
  IF v_payment.status = 'paid' THEN
    RETURN jsonb_build_object('message', 'Already processed');
  END IF;

  -- Get booking with lock
  SELECT * INTO v_booking FROM bookings WHERE id = v_payment.booking_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found for payment';
  END IF;

  -- FIX (v8.9): Venue service type charges more than the stored service_amount because
  -- platformFee + yocoFee are added on top of the fixer's quoted price.
  -- The payments row stores the original service_amount (e.g. R200), but Yoco processes
  -- the full blended amount (e.g. R230.62).  The old ABS check threw an exception for
  -- every venue booking, silently killing the webhook and leaving the customer stranded.
  --
  -- New rule: only reject if Yoco paid LESS than the stored amount (genuine underpayment /
  -- fraud).  Overpayment (venue fees passed through) is accepted; we record what was
  -- actually captured so reconciliation is accurate.
  IF p_amount < (v_payment.amount - 0.01) THEN
    RAISE EXCEPTION 'Underpayment: expected at least %, got %', v_payment.amount, p_amount;
  END IF;

  -- Validate booking is in correct state for payment
  IF v_booking.payment_status != 'pending' OR v_booking.status NOT IN ('CREATED', 'PENDING_PAYMENT') THEN
    RAISE EXCEPTION 'Booking % not ready for payment confirmation', v_booking.id;
  END IF;

  -- Update payment — record actual captured amount for reconciliation
  UPDATE payments SET
    status               = 'paid',
    provider_payment_id  = p_provider_payment_id,
    amount_captured      = p_amount,  -- actual Yoco charge; may exceed service_amount for venue
    verified_at          = now(),
    updated_at           = now()
  WHERE id = p_payment_id;

  -- Update booking
  UPDATE bookings SET
    payment_status       = 'paid',
    payment_reference    = p_provider_payment_id,
    payment_confirmed_at = now(),
    status               = 'SEARCHING',
    updated_at           = now(),
    version              = version + 1
  WHERE id = v_booking.id
  RETURNING * INTO v_booking;

  -- Create audit event
  INSERT INTO booking_events (
    booking_id,
    event_type,
    old_status,
    new_status,
    metadata
  ) VALUES (
    v_booking.id,
    'payment_confirmed',
    'PENDING_PAYMENT',
    'SEARCHING',
    jsonb_build_object(
      'payment_id',      p_provider_payment_id,
      'amount_captured', p_amount,
      'amount_service',  v_payment.amount
    )
  );

  -- Trigger matching (via pg_notify for Edge Function)
  PERFORM pg_notify(
    'booking_paid',
    jsonb_build_object('booking_id', v_booking.id)::text
  );

  RETURN jsonb_build_object(
    'success',          true,
    'booking_id',       v_booking.id,
    'status',           v_booking.status,
    'amount_captured',  p_amount,
    'amount_service',   v_payment.amount
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- SECTION 3 — Index to support the reopen-after-payment fix
--             (OR query: payment_status='paid' OR created_at recent)
-- ─────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_bookings_pending_payment_created_at
  ON bookings (customer_id, status, payment_status, created_at DESC)
  WHERE status IN ('PENDING_PAYMENT', 'CREATED');

-- ─────────────────────────────────────────────────────────────────
-- SECTION 4 — Sanity-check: confirm the function was updated
-- ─────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_def TEXT;
BEGIN
  SELECT prosrc INTO v_def
  FROM pg_proc
  WHERE proname = 'process_yoco_payment_success'
  LIMIT 1;

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'process_yoco_payment_success not found after migration';
  END IF;

  IF v_def NOT LIKE '%Underpayment%' THEN
    RAISE EXCEPTION 'process_yoco_payment_success was not updated — old version still active';
  END IF;

  RAISE NOTICE 'v8.9 migration verified: process_yoco_payment_success updated correctly';
END;
$$;
