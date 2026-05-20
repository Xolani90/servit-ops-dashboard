-- ═══════════════════════════════════════════════════════════════
-- SERVIT v5.1 — Audit Compliance Migration
-- Fixes audit failures 1–4:
--   F1: Unguarded available toggle → toggle_fixer_availability() + RLS
--   F2: Commission rate mismatch → platform_commission_pct() constant
--   F3: validate_booking_transition() dead code → wired into update_job_status()
--   F4: No pre-match cancellation refund → mark_payment_refunded() helper
-- Run this after the v5 schema is applied.
-- ═══════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────
-- FIX 2: Single source of truth for commission rate
--
-- BEFORE: create_payout() had `p_commission_pct NUMERIC DEFAULT 15.0`
--         The signup screen and booking preview both showed 12%.
--         Fixers were quoted 12% and charged 15%.
--
-- AFTER:  One immutable function returns 12.0. create_payout() and
--         any future function use it. The number lives in one place.
-- ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION platform_commission_pct()
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 12.0;
$$;

-- Update create_payout() to use the constant instead of a hardcoded 15.0
CREATE OR REPLACE FUNCTION create_payout(
  p_booking_id     UUID,
  p_commission_pct NUMERIC DEFAULT platform_commission_pct()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking      bookings%ROWTYPE;
  v_gross        NUMERIC(10,2);
  v_commission   NUMERIC(10,2);
  v_net          NUMERIC(10,2);
  v_payout_id    UUID;
BEGIN
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;

  -- Idempotent: skip if payout already exists
  IF EXISTS (SELECT 1 FROM payouts WHERE booking_id = p_booking_id) THEN
    RETURN jsonb_build_object('message', 'Payout already exists');
  END IF;

  -- No fixer = nothing to pay
  IF v_booking.fixer_id IS NULL THEN
    RETURN jsonb_build_object('message', 'No fixer assigned, skipping payout');
  END IF;

  v_gross      := v_booking.amount;
  v_commission := ROUND((v_gross * p_commission_pct / 100)::numeric, 2);
  v_net        := v_gross - v_commission;

  INSERT INTO payouts (
    booking_id, fixer_id, gross_amount, commission_pct,
    commission_amt, net_amount, status, hold_until
  ) VALUES (
    p_booking_id,
    v_booking.fixer_id,
    v_gross,
    p_commission_pct,
    v_commission,
    v_net,
    'held',
    now() + interval '24 hours'
  )
  RETURNING id INTO v_payout_id;

  -- Notify fixer
  INSERT INTO notifications (user_id, title, body, type, related_id)
  SELECT
    f.user_id,
    '💰 Payment queued',
    'Your payment of R' || v_net::TEXT || ' will be released in 24 hours.',
    'payout_created',
    p_booking_id
  FROM fixers f WHERE f.id = v_booking.fixer_id;

  RETURN jsonb_build_object(
    'success',    true,
    'payout_id',  v_payout_id,
    'gross',      v_gross,
    'commission', v_commission,
    'net',        v_net,
    'hold_until', now() + interval '24 hours'
  );
END;
$$;


-- ───────────────────────────────────────────────────────────────
-- FIX 3: Wire validate_booking_transition() into update_job_status()
--
-- BEFORE: validate_booking_transition() existed but was never called.
--         update_job_status() re-implemented its own CASE block.
--         Future DB functions had no shared transition gate.
--
-- AFTER:  update_job_status() calls validate_booking_transition()
--         first, then applies the role check on top. The CASE block
--         is removed — validate_booking_transition() IS the gate.
--
-- Also adds two missing transitions to validate_booking_transition():
--   DISPUTED → COMPLETED  (resolve_dispute outcome: pay_fixer)
--   DISPUTED → CANCELLED  (resolve_dispute outcome: refund_customer / dismissed)
--
-- Also adds missing cancellation paths for EN_ROUTE (fixer cancel):
--   EN_ROUTE → CANCELLED  (fixer bails after leaving, before arriving)
-- ───────────────────────────────────────────────────────────────

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
    -- Normal forward flow
    (old_status = 'CREATED'             AND new_status = 'PENDING_PAYMENT') OR
    (old_status = 'PENDING_PAYMENT'     AND new_status = 'SEARCHING') OR
    (old_status = 'SEARCHING'           AND new_status = 'OFFERED') OR
    (old_status = 'OFFERED'             AND new_status = 'CONFIRMED') OR
    (old_status = 'OFFERED'             AND new_status = 'SEARCHING') OR  -- decline / expire
    (old_status = 'CONFIRMED'           AND new_status = 'EN_ROUTE') OR
    (old_status = 'EN_ROUTE'            AND new_status = 'ARRIVED') OR
    (old_status = 'ARRIVED'             AND new_status = 'IN_PROGRESS') OR
    (old_status = 'IN_PROGRESS'         AND new_status = 'PENDING_COMPLETION') OR
    (old_status = 'PENDING_COMPLETION'  AND new_status = 'COMPLETED') OR

    -- Dispute paths
    (old_status = 'CONFIRMED'           AND new_status = 'DISPUTED') OR
    (old_status = 'IN_PROGRESS'         AND new_status = 'DISPUTED') OR
    (old_status = 'PENDING_COMPLETION'  AND new_status = 'DISPUTED') OR
    -- resolve_dispute() outcomes (previously missing — were only guarded ad-hoc)
    (old_status = 'DISPUTED'            AND new_status = 'COMPLETED') OR
    (old_status = 'DISPUTED'            AND new_status = 'CANCELLED') OR

    -- Cancellation paths (role check in update_job_status narrows who can use each)
    (old_status = 'PENDING_PAYMENT'     AND new_status = 'CANCELLED') OR
    (old_status = 'PENDING_PAYMENT'     AND new_status = 'EXPIRED') OR
    (old_status = 'SEARCHING'           AND new_status = 'CANCELLED') OR
    (old_status = 'OFFERED'             AND new_status = 'CANCELLED') OR
    (old_status = 'OFFERED'             AND new_status = 'EXPIRED') OR
    (old_status = 'CONFIRMED'           AND new_status = 'CANCELLED') OR
    (old_status = 'EN_ROUTE'            AND new_status = 'CANCELLED') OR  -- fixer abort (added)
    (old_status = 'ARRIVED'             AND new_status = 'CANCELLED')
  );
END;
$$;

-- Rewire update_job_status() to use validate_booking_transition() as the primary gate
CREATE OR REPLACE FUNCTION update_job_status(
  p_booking_id    UUID,
  p_actor_user_id UUID,
  p_new_status    TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking     bookings%ROWTYPE;
  v_old_status  TEXT;
  v_is_fixer    BOOLEAN;
  v_is_customer BOOLEAN;
  v_role_ok     BOOLEAN;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;

  v_old_status  := v_booking.status;
  v_is_fixer    := EXISTS(SELECT 1 FROM fixers WHERE user_id = p_actor_user_id AND id = v_booking.fixer_id);
  v_is_customer := (v_booking.customer_id = p_actor_user_id);

  -- ── Gate 1: Is this transition structurally valid at all? ──
  IF NOT validate_booking_transition(
    v_old_status::booking_status_enum,
    p_new_status::booking_status_enum
  ) THEN
    RAISE EXCEPTION 'Invalid status transition: % → %', v_old_status, p_new_status;
  END IF;

  -- ── Gate 2: Does this actor's role allow this specific transition? ──
  v_role_ok := CASE p_new_status
    WHEN 'EN_ROUTE'            THEN v_is_fixer
    WHEN 'ARRIVED'             THEN v_is_fixer
    WHEN 'IN_PROGRESS'         THEN v_is_fixer
    WHEN 'PENDING_COMPLETION'  THEN v_is_fixer
    WHEN 'COMPLETED'           THEN v_is_customer
    WHEN 'DISPUTED'            THEN v_is_customer OR v_is_fixer
    WHEN 'CANCELLED' THEN
      (v_is_customer AND v_old_status IN ('CREATED', 'PENDING_PAYMENT', 'SEARCHING', 'OFFERED', 'CONFIRMED'))
      OR
      (v_is_fixer    AND v_old_status IN ('CONFIRMED', 'EN_ROUTE', 'ARRIVED'))
    ELSE false
  END;

  IF NOT v_role_ok THEN
    RAISE EXCEPTION 'Role not permitted for transition % → % (fixer=%, customer=%)',
      v_old_status, p_new_status, v_is_fixer, v_is_customer;
  END IF;

  -- ── Apply the transition ──────────────────────────────────
  UPDATE bookings SET
    status     = p_new_status,
    updated_at = now(),
    version    = version + 1
  WHERE id = p_booking_id;

  IF p_new_status = 'EN_ROUTE' THEN
    UPDATE bookings SET en_route_at = now() WHERE id = p_booking_id;
  ELSIF p_new_status = 'ARRIVED' THEN
    UPDATE bookings SET arrived_at = now() WHERE id = p_booking_id;
  ELSIF p_new_status = 'IN_PROGRESS' THEN
    UPDATE bookings SET in_progress_at = now() WHERE id = p_booking_id;
  ELSIF p_new_status = 'PENDING_COMPLETION' THEN
    UPDATE bookings SET pending_completion_at = now() WHERE id = p_booking_id;
  ELSIF p_new_status = 'COMPLETED' THEN
    UPDATE bookings SET completed_at = now() WHERE id = p_booking_id;

    UPDATE fixers SET available = true, updated_at = now()
    WHERE id = v_booking.fixer_id;

    UPDATE fixers SET
      jobs_completed  = jobs_completed + 1,
      acceptance_rate = LEAST(100, ROUND((acceptance_rate * 9.0 + 100.0) / 10.0)),
      updated_at      = now()
    WHERE id = v_booking.fixer_id;

    PERFORM create_payout(p_booking_id);

    INSERT INTO notifications (user_id, title, body, type, related_id)
    VALUES (
      v_booking.customer_id,
      '⭐ How was your experience?',
      'Leave a review for your fixer — it helps the community!',
      'review_prompt',
      p_booking_id
    );

  ELSIF p_new_status = 'CANCELLED' THEN
    UPDATE bookings SET cancelled_at = now() WHERE id = p_booking_id;
    IF v_booking.fixer_id IS NOT NULL THEN
      UPDATE fixers SET available = true, updated_at = now()
      WHERE id = v_booking.fixer_id;
    END IF;
  END IF;

  INSERT INTO booking_events (
    booking_id, event_type, old_status, new_status, created_by
  ) VALUES (
    p_booking_id, 'status_update', v_old_status, p_new_status, p_actor_user_id
  );

  RETURN jsonb_build_object(
    'success',    true,
    'booking_id', p_booking_id,
    'old_status', v_old_status,
    'new_status', p_new_status
  );
END;
$$;


-- ───────────────────────────────────────────────────────────────
-- FIX 1: Secure availability toggle
--
-- BEFORE: Frontend called supabaseClient.from('fixers').update({ available })
--         directly with the anon key. No RLS on the available column.
--         Any authenticated user could disable any fixer. A fixer could
--         set available = true while a job was IN_PROGRESS.
--
-- AFTER:
--   • toggle_fixer_availability() — SECURITY DEFINER function that:
--       - Verifies caller owns the fixer row (p_user_id = fixers.user_id)
--       - Blocks going online while a job is active
--       - Atomically flips the flag
--   • RLS policies on fixers table added below
--   • Trigger guard on the available column (blocks direct REST writes)
--   • Frontend calls /api/toggle-availability (Netlify function) instead
-- ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION toggle_fixer_availability(p_fixer_id UUID, p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fixer     fixers%ROWTYPE;
  v_new_avail BOOLEAN;
BEGIN
  -- Ownership check: the caller must own this fixer row
  SELECT * INTO v_fixer
  FROM fixers
  WHERE id = p_fixer_id AND user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixer not found or not owned by this user';
  END IF;

  -- Cannot go online while a job is actively in progress
  IF NOT v_fixer.available THEN
    IF EXISTS (
      SELECT 1 FROM bookings
      WHERE fixer_id = p_fixer_id
        AND status IN ('CONFIRMED', 'EN_ROUTE', 'ARRIVED', 'IN_PROGRESS', 'PENDING_COMPLETION')
    ) THEN
      RAISE EXCEPTION 'Cannot go online while a job is active';
    END IF;
  END IF;

  v_new_avail := NOT v_fixer.available;

  UPDATE fixers
  SET available  = v_new_avail,
      updated_at = now()
  WHERE id = p_fixer_id;

  RETURN jsonb_build_object(
    'success',   true,
    'fixer_id',  p_fixer_id,
    'available', v_new_avail
  );
END;
$$;

-- RLS on fixers table
ALTER TABLE fixers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fixers_select_public      ON fixers;
DROP POLICY IF EXISTS fixers_update_own         ON fixers;
DROP POLICY IF EXISTS fixers_insert_own         ON fixers;

-- Anyone can read fixer profiles (needed for matching display, reviews, etc.)
CREATE POLICY fixers_select_public ON fixers
  FOR SELECT USING (true);

-- Fixers can update their own row — but the available column is guarded by trigger below
CREATE POLICY fixers_update_own ON fixers
  FOR UPDATE USING (auth.uid() = user_id);

-- Trigger: block direct REST writes to the `available` column
-- Only SECURITY DEFINER functions (toggle_fixer_availability, update_job_status)
-- may change it. Direct anon/authenticated REST calls are rejected.
CREATE OR REPLACE FUNCTION prevent_direct_available_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.available IS DISTINCT FROM OLD.available THEN
    -- Allow if called from one of our SECURITY DEFINER functions
    IF current_setting('app.allow_status_change', true) IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'Direct update to fixers.available is not permitted. Use the toggle-availability API.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prevent_direct_fixer_available_update ON fixers;
CREATE TRIGGER prevent_direct_fixer_available_update
  BEFORE UPDATE ON fixers
  FOR EACH ROW
  EXECUTE FUNCTION prevent_direct_available_update();

-- toggle_fixer_availability() is SECURITY DEFINER so it needs to set the flag
-- to bypass the trigger, same pattern as update_job_status() does for booking status.
-- We reuse the existing app.allow_status_change session variable for this.
CREATE OR REPLACE FUNCTION toggle_fixer_availability(p_fixer_id UUID, p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fixer     fixers%ROWTYPE;
  v_new_avail BOOLEAN;
BEGIN
  SELECT * INTO v_fixer
  FROM fixers
  WHERE id = p_fixer_id AND user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixer not found or not owned by this user';
  END IF;

  IF NOT v_fixer.available THEN
    IF EXISTS (
      SELECT 1 FROM bookings
      WHERE fixer_id = p_fixer_id
        AND status IN ('CONFIRMED', 'EN_ROUTE', 'ARRIVED', 'IN_PROGRESS', 'PENDING_COMPLETION')
    ) THEN
      RAISE EXCEPTION 'Cannot go online while a job is active';
    END IF;
  END IF;

  v_new_avail := NOT v_fixer.available;

  -- Set flag so the trigger allows this SECURITY DEFINER write
  PERFORM set_config('app.allow_status_change', 'true', true);

  UPDATE fixers
  SET available  = v_new_avail,
      updated_at = now()
  WHERE id = p_fixer_id;

  RETURN jsonb_build_object(
    'success',   true,
    'fixer_id',  p_fixer_id,
    'available', v_new_avail
  );
END;
$$;


-- ───────────────────────────────────────────────────────────────
-- FIX 4 (helper): mark_payment_refunded
--
-- Called by the cancel-booking Netlify function after a successful
-- Yoco refund API call. Atomically marks the payment as refunded
-- and records the event in booking_events.
-- ───────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION mark_payment_refunded(
  p_booking_id UUID,
  p_payment_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE payments
  SET status     = 'refunded',
      updated_at = now()
  WHERE id = p_payment_id
    AND booking_id = p_booking_id
    AND status = 'paid';    -- idempotency guard: only refund once

  IF NOT FOUND THEN
    RETURN jsonb_build_object('message', 'Payment already refunded or not found');
  END IF;

  INSERT INTO booking_events (
    booking_id, event_type, old_status, new_status, created_by
  )
  SELECT
    p_booking_id,
    'payment_refunded',
    'paid',
    'refunded',
    customer_id
  FROM bookings
  WHERE id = p_booking_id;

  RETURN jsonb_build_object('success', true, 'payment_id', p_payment_id);
END;
$$;
