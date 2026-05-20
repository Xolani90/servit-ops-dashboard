-- ═══════════════════════════════════════════════════════════════
-- decline_offer — fixed for actual schema (fixers, not pro_profiles)
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION decline_offer(
  p_offer_id      UUID,
  p_fixer_id      UUID,
  p_fixer_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offer        offers%ROWTYPE;
  v_booking      bookings%ROWTYPE;
  v_verify_owner UUID;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT user_id INTO v_verify_owner FROM fixers WHERE id = p_fixer_id;

  IF v_verify_owner IS NULL OR v_verify_owner != p_fixer_user_id THEN
    RAISE EXCEPTION 'Unauthorized: fixer does not own this offer';
  END IF;

  SELECT * INTO v_offer FROM offers WHERE id = p_offer_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Offer not found';
  END IF;

  IF v_offer.status != 'pending' THEN
    RAISE EXCEPTION 'Offer already %', v_offer.status;
  END IF;

  UPDATE offers SET
    status       = 'declined',
    responded_at = now()
  WHERE id = p_offer_id;

  -- Decrement acceptance_rate (EMA, weight 10)
  UPDATE fixers SET
    acceptance_rate = GREATEST(0, ROUND((acceptance_rate * 9.0) / 10.0)),
    updated_at      = now()
  WHERE id = p_fixer_id;

  SELECT * INTO v_booking FROM bookings WHERE id = v_offer.booking_id FOR UPDATE;

  IF v_booking.status = 'OFFERED' THEN
    IF NOT EXISTS (
      SELECT 1 FROM offers
      WHERE  booking_id = v_booking.id
        AND  id        != p_offer_id
        AND  status     = 'pending'
    ) THEN
      UPDATE bookings SET
        status           = 'SEARCHING',
        current_offer_id = NULL,
        offer_expires_at = NULL,
        updated_at       = now(),
        version          = version + 1
      WHERE id = v_booking.id;

      INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata)
      VALUES (
        v_booking.id, 'offer_declined_no_alternatives', 'OFFERED', 'SEARCHING',
        jsonb_build_object('offer_id', p_offer_id, 'fixer_id', p_fixer_id)
      );

      PERFORM pg_notify(
        'booking_paid',
        jsonb_build_object('booking_id', v_booking.id)::text
      );
    ELSE
      INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata)
      VALUES (
        v_booking.id, 'offer_declined_has_alternatives', 'OFFERED', 'OFFERED',
        jsonb_build_object('offer_id', p_offer_id, 'fixer_id', p_fixer_id)
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success',    true,
    'booking_id', v_booking.id
  );
END;
$$;
