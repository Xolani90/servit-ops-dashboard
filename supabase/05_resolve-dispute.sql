-- ═══════════════════════════════════════════════════════════════
-- resolve_dispute — v5.2
-- FIX 7 (Issue 2): Now calls validate_booking_transition() before
-- the raw UPDATE. Previously the function bypassed the shared state
-- machine gate entirely. An admin passing a booking already in
-- COMPLETED would silently overwrite good state.
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION resolve_dispute(
  p_dispute_id  UUID,
  p_admin_id    UUID,
  p_outcome     TEXT,
  p_admin_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dispute       disputes%ROWTYPE;
  v_booking       bookings%ROWTYPE;
  v_payout        payouts%ROWTYPE;
  v_target_status TEXT;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  IF p_outcome NOT IN ('refund_customer','pay_fixer','split','dismissed') THEN
    RAISE EXCEPTION 'Invalid outcome: %', p_outcome;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = p_admin_id AND user_role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only admins can resolve disputes';
  END IF;

  SELECT * INTO v_dispute FROM disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dispute not found';
  END IF;

  IF v_dispute.resolved_at IS NOT NULL THEN
    RAISE EXCEPTION 'Dispute already resolved at %', v_dispute.resolved_at;
  END IF;

  SELECT * INTO v_booking FROM bookings WHERE id = v_dispute.booking_id FOR UPDATE;

  -- Primary guard: booking must be in DISPUTED
  IF v_booking.status != 'DISPUTED' THEN
    RAISE EXCEPTION 'Booking is not in DISPUTED state (current: %)', v_booking.status;
  END IF;

  -- Determine target status from outcome
  v_target_status := CASE
    WHEN p_outcome = 'refund_customer' THEN 'CANCELLED'
    ELSE 'COMPLETED'
  END;

  -- FIX 7: Explicitly validate through the shared state machine gate.
  -- validate_booking_transition() now includes DISPUTED → COMPLETED
  -- and DISPUTED → CANCELLED (added in v5.1, confirmed in v5.2 schema).
  IF NOT validate_booking_transition(
    v_booking.status::booking_status_enum,
    v_target_status::booking_status_enum
  ) THEN
    RAISE EXCEPTION 'resolve_dispute: invalid transition DISPUTED → % for outcome "%"',
      v_target_status, p_outcome;
  END IF;

  SELECT * INTO v_payout FROM payouts WHERE booking_id = v_booking.id FOR UPDATE;

  CASE p_outcome

    WHEN 'refund_customer' THEN
      IF v_payout.id IS NOT NULL THEN
        UPDATE payouts SET
          status     = 'cancelled',
          notes      = COALESCE(notes || ' | ', '') || 'Cancelled: dispute resolved in customer favour',
          updated_at = now()
        WHERE id = v_payout.id;
      END IF;
      INSERT INTO notifications (user_id, title, body, type, related_id)
      VALUES (
        v_booking.customer_id,
        '💰 Refund approved',
        'Your dispute was resolved in your favour. A refund is being processed.',
        'dispute_resolved',
        v_dispute.booking_id
      );
      INSERT INTO notifications (user_id, title, body, type, related_id)
      SELECT f.user_id,
        '📋 Dispute outcome',
        'The dispute has been resolved. Payment has been refunded to the customer.',
        'dispute_resolved',
        v_dispute.booking_id
      FROM fixers f WHERE f.id = v_booking.fixer_id;

    WHEN 'pay_fixer' THEN
      IF v_payout.id IS NOT NULL THEN
        UPDATE payouts SET
          status      = 'released',
          hold_until  = now(),
          released_at = now(),
          notes       = COALESCE(notes || ' | ', '') || 'Released: dispute resolved in fixer favour',
          updated_at  = now()
        WHERE id = v_payout.id;
      END IF;
      INSERT INTO notifications (user_id, title, body, type, related_id)
      SELECT f.user_id,
        '✅ Payment released',
        'The dispute was resolved in your favour. Your payment has been released.',
        'dispute_resolved',
        v_dispute.booking_id
      FROM fixers f WHERE f.id = v_booking.fixer_id;

    WHEN 'split', 'dismissed' THEN
      IF v_payout.id IS NOT NULL AND v_payout.status = 'held' THEN
        UPDATE payouts SET
          notes      = COALESCE(notes || ' | ', '') || 'Dispute ' || p_outcome || ' — normal payout proceeds',
          updated_at = now()
        WHERE id = v_payout.id;
      END IF;
      INSERT INTO notifications (user_id, title, body, type, related_id)
      VALUES (
        v_booking.customer_id,
        '📋 Dispute closed',
        'Your dispute has been reviewed and closed.',
        'dispute_resolved',
        v_dispute.booking_id
      );
  END CASE;

  UPDATE disputes SET
    resolution  = p_outcome,
    outcome     = p_outcome,
    resolved_by = p_admin_id,
    admin_notes = p_admin_notes,
    resolved_at = now(),
    updated_at  = now()
  WHERE id = p_dispute_id;

  -- Apply the transition (validate_booking_transition already passed above)
  UPDATE bookings SET
    status     = v_target_status,
    updated_at = now(),
    version    = version + 1
  WHERE id = v_booking.id;

  IF v_booking.fixer_id IS NOT NULL THEN
    UPDATE fixers SET available = true, updated_at = now()
    WHERE id = v_booking.fixer_id;
  END IF;

  INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata, created_by)
  VALUES (
    v_booking.id,
    'dispute_resolved',
    'DISPUTED',
    v_target_status::booking_status_enum,
    jsonb_build_object('dispute_id', p_dispute_id, 'outcome', p_outcome),
    p_admin_id
  );

  RETURN jsonb_build_object(
    'success',    true,
    'dispute_id', p_dispute_id,
    'outcome',    p_outcome,
    'booking_id', v_booking.id
  );
END;
$$;
