-- ═══════════════════════════════════════════════════════════════
-- create_payment_session
-- Creates a payment record and returns checkout info
-- This is called via Edge Function, not directly from frontend
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION create_payment_session(
  p_booking_id UUID,
  p_customer_id UUID,
  p_amount NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payment_id UUID;
  v_booking bookings%ROWTYPE;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);
  -- Get and lock booking
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;
  
  -- Verify customer owns booking
  IF v_booking.customer_id != p_customer_id THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;
  
  -- Verify booking is in correct state
  IF v_booking.status != 'CREATED' OR v_booking.payment_status != 'pending' THEN
    RAISE EXCEPTION 'Booking not ready for payment';
  END IF;
  
  -- Update booking to PENDING_PAYMENT
  UPDATE bookings SET
    status = 'PENDING_PAYMENT',
    updated_at = now(),
    version = version + 1
  WHERE id = p_booking_id;
  
  -- Create payment record
  INSERT INTO payments (
    booking_id,
    amount,
    status
  ) VALUES (
    p_booking_id,
    p_amount,
    'pending'
  )
  RETURNING id INTO v_payment_id;
  
  -- Create audit event
  INSERT INTO booking_events (
    booking_id,
    event_type,
    old_status,
    new_status,
    created_by
  ) VALUES (
    p_booking_id,
    'payment_initiated',
    'CREATED',
    'PENDING_PAYMENT',
    p_customer_id
  );
  
  RETURN jsonb_build_object(
    'payment_id', v_payment_id,
    'booking_id', p_booking_id,
    'amount', p_amount
  );
END;
$$;