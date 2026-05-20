-- ═══════════════════════════════════════════════════════════════
-- raise_dispute
-- Customer or fixer raises a dispute on an active booking
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION raise_dispute(
  p_booking_id UUID,
  p_user_id UUID,
  p_reason TEXT,
  p_evidence_url TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking bookings%ROWTYPE;
  v_user_role TEXT;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);
  -- Get booking
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;
  
  -- Verify user is involved
  IF v_booking.customer_id != p_user_id AND (SELECT user_id FROM fixers WHERE id = v_booking.fixer_id) != p_user_id THEN
    RAISE EXCEPTION 'Not authorized to raise dispute';
  END IF;
  
  -- Only allow disputes on active bookings (after confirmation, before completion)
  IF v_booking.status NOT IN ('CONFIRMED', 'EN_ROUTE', 'ARRIVED', 'IN_PROGRESS', 'PENDING_COMPLETION') THEN
    RAISE EXCEPTION 'Cannot raise dispute on booking in % state', v_booking.status;
  END IF;
  
  -- Create dispute record
  INSERT INTO disputes (
    booking_id,
    raised_by,
    reason,
    evidence_url
  ) VALUES (
    p_booking_id,
    p_user_id,
    p_reason,
    p_evidence_url
  );
  
  -- Update booking status
  UPDATE bookings SET
    status = 'DISPUTED',
    updated_at = now(),
    version = version + 1
  WHERE id = p_booking_id;
  
  -- Audit event
  INSERT INTO booking_events (
    booking_id,
    event_type,
    old_status,
    new_status,
    metadata,
    created_by
  ) VALUES (
    p_booking_id,
    'dispute_raised',
    v_booking.status,
    'DISPUTED',
    jsonb_build_object('reason', p_reason),
    p_user_id
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'booking_id', p_booking_id,
    'status', 'DISPUTED'
  );
END;
$$;