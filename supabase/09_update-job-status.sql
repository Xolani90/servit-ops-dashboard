-- ═══════════════════════════════════════════════════════════════
-- update_job_status — v5.2 CANONICAL VERSION
-- This file supersedes supabase/functions/09_update-job-status.sql
-- which must be deleted from the repository.
--
-- Changes from v5.1:
--   FIX 3: This is the single authoritative version. The old
--           09_update-job-status.sql (CASE block, no validate gate)
--           must be git rm'd.
--   FIX 4: Fixer post-acceptance cancellation now:
--           • Decrements acceptance_rate (rolling 10-job penalty)
--           • Releases the fixer
--           • Resets booking to SEARCHING with fixer_id = NULL
--           • Notifies customer
--           • Calls match_fixers() for immediate rematch
--           • Returns early with new_status = 'SEARCHING'
--           Previously: fixer could bail with no consequence and
--           customer was left stranded with no rematch.
--   FIX 2/Issue 1: mark_payment_refunded fixed separately — this
--           function does not touch mark_payment_refunded.
-- ═══════════════════════════════════════════════════════════════

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

  -- ── Gate 1: structural validity via shared state machine ─────
  IF NOT validate_booking_transition(
    v_old_status::booking_status_enum,
    p_new_status::booking_status_enum
  ) THEN
    RAISE EXCEPTION 'Invalid status transition: % → %', v_old_status, p_new_status;
  END IF;

  -- ── Gate 2: role permission ───────────────────────────────────
  v_role_ok := CASE p_new_status
    WHEN 'EN_ROUTE'            THEN v_is_fixer
    WHEN 'ARRIVED'             THEN v_is_fixer
    WHEN 'IN_PROGRESS'         THEN v_is_fixer
    WHEN 'PENDING_COMPLETION'  THEN v_is_fixer
    WHEN 'COMPLETED'           THEN v_is_customer
    WHEN 'DISPUTED'            THEN v_is_customer OR v_is_fixer
    WHEN 'CANCELLED' THEN
      (v_is_customer AND v_old_status IN ('CREATED','PENDING_PAYMENT','SEARCHING','OFFERED','CONFIRMED'))
      OR
      (v_is_fixer    AND v_old_status IN ('CONFIRMED','EN_ROUTE','ARRIVED'))
    ELSE false
  END;

  IF NOT v_role_ok THEN
    RAISE EXCEPTION 'Role not permitted for transition % → % (fixer=%, customer=%)',
      v_old_status, p_new_status, v_is_fixer, v_is_customer;
  END IF;

  -- ── Apply transition ──────────────────────────────────────────
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

    -- Release fixer and reward stats
    UPDATE fixers SET
      available       = true,
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

    -- ── FIX 4: Fixer post-acceptance cancellation ────────────────
    -- BEFORE: fixer could cancel CONFIRMED/EN_ROUTE/ARRIVED with no
    --   penalty. acceptance_rate was only decremented on decline_offer.
    --   No auto-rematch was triggered. Customer was left stranded.
    -- AFTER: penalty applied, fixer released, booking reset to
    --   SEARCHING, customer notified, match_fixers() called immediately.
    IF v_is_fixer AND v_old_status IN ('CONFIRMED', 'EN_ROUTE', 'ARRIVED') THEN

      -- Penalise acceptance_rate (rolling 10-job EMA window)
      UPDATE fixers SET
        acceptance_rate = GREATEST(0, ROUND((acceptance_rate * 9.0) / 10.0)),
        updated_at      = now()
      WHERE id = v_booking.fixer_id;

      -- Release fixer (only if not mid another job, which shouldn't happen
      -- but guard defensively)
      UPDATE fixers SET available = true, updated_at = now()
      WHERE id = v_booking.fixer_id
        AND NOT EXISTS (
          SELECT 1 FROM bookings
          WHERE  fixer_id = v_booking.fixer_id
            AND  status   IN ('CONFIRMED','EN_ROUTE','ARRIVED','IN_PROGRESS','PENDING_COMPLETION')
            AND  id       != p_booking_id
        );

      -- Clear fixer assignment and push booking back to SEARCHING for rematch.
      -- allow_status_change is already set in this session.
      UPDATE bookings SET
        fixer_id         = NULL,
        status           = 'SEARCHING',
        current_offer_id = NULL,
        offer_expires_at = NULL,
        updated_at       = now(),
        version          = version + 1
      WHERE id = p_booking_id;

      -- Notify customer their fixer bailed
      INSERT INTO notifications (user_id, title, body, type, related_id)
      VALUES (
        v_booking.customer_id,
        '⚠️ Fixer cancelled',
        'Your fixer cancelled. We are finding you a new one now.',
        'fixer_cancelled',
        p_booking_id
      );

      -- Audit log for this specific event
      INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata, created_by)
      VALUES (
        p_booking_id,
        'fixer_cancelled_rematch',
        v_old_status::booking_status_enum,
        'SEARCHING',
        jsonb_build_object(
          'fixer_id',    v_booking.fixer_id,
          'old_status',  v_old_status,
          'penalty',     'acceptance_rate_decremented'
        ),
        p_actor_user_id
      );

      -- Trigger immediate rematch
      PERFORM match_fixers(p_booking_id);

      -- Return early — booking is now SEARCHING, not CANCELLED
      RETURN jsonb_build_object(
        'success',    true,
        'booking_id', p_booking_id,
        'old_status', v_old_status,
        'new_status', 'SEARCHING',
        'note',       'Fixer cancelled post-acceptance. Booking returned to SEARCHING for rematch.'
      );

    ELSE
      -- Customer cancellation, or fixer cancelling before CONFIRMED (pre-assignment)
      IF v_booking.fixer_id IS NOT NULL THEN
        UPDATE fixers SET available = true, updated_at = now()
        WHERE id = v_booking.fixer_id;
      END IF;
    END IF;
  END IF;

  -- Generic audit log for all non-early-return transitions
  INSERT INTO booking_events (
    booking_id, event_type, old_status, new_status, created_by
  ) VALUES (
    p_booking_id,
    'status_update',
    v_old_status::booking_status_enum,
    p_new_status::booking_status_enum,
    p_actor_user_id
  );

  RETURN jsonb_build_object(
    'success',    true,
    'booking_id', p_booking_id,
    'old_status', v_old_status,
    'new_status', p_new_status
  );
END;
$$;
