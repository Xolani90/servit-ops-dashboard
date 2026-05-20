-- ═══════════════════════════════════════════════════════════════
-- accept_offer — fixed for actual schema (fixers, not pro_profiles)
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION accept_offer(
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
  v_losing_fixer RECORD;
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

  IF v_offer.expires_at < now() THEN
    UPDATE offers SET status = 'expired' WHERE id = p_offer_id;
    RAISE EXCEPTION 'Offer has expired';
  END IF;

  SELECT * INTO v_booking FROM bookings WHERE id = v_offer.booking_id FOR UPDATE;

  IF v_booking.status != 'OFFERED' THEN
    RAISE EXCEPTION 'Booking is not in OFFERED state (current: %)', v_booking.status;
  END IF;

  UPDATE offers SET
    status       = 'accepted',
    responded_at = now()
  WHERE id = p_offer_id;

  UPDATE bookings SET
    status           = 'CONFIRMED',
    fixer_id         = v_offer.fixer_id,
    confirmed_at     = now(),
    current_offer_id = p_offer_id,
    updated_at       = now(),
    version          = version + 1
  WHERE id = v_booking.id;

  UPDATE fixers SET
    available  = false,
    updated_at = now()
  WHERE id = v_offer.fixer_id;

  -- Expire all other pending offers for this booking
  FOR v_losing_fixer IN
    SELECT o.id AS offer_id, f.user_id AS fixer_user_id
    FROM   offers o
    JOIN   fixers f ON f.id = o.fixer_id
    WHERE  o.booking_id = v_booking.id
      AND  o.id        != p_offer_id
      AND  o.status     = 'pending'
    FOR UPDATE OF o SKIP LOCKED
  LOOP
    UPDATE offers SET
      status       = 'expired',
      responded_at = now()
    WHERE id = v_losing_fixer.offer_id;

    INSERT INTO notifications (user_id, title, body, type, related_id)
    VALUES (
      v_losing_fixer.fixer_user_id,
      '⚡ Job taken',
      'Another fixer accepted this job first. Stay available for the next one!',
      'offer_expired',
      v_booking.id
    );
  END LOOP;

  INSERT INTO booking_events (
    booking_id, event_type, old_status, new_status, metadata, created_by
  ) VALUES (
    v_booking.id, 'offer_accepted', 'OFFERED', 'CONFIRMED',
    jsonb_build_object('offer_id', p_offer_id, 'fixer_id', v_offer.fixer_id),
    p_fixer_user_id
  );

  RETURN jsonb_build_object(
    'success',    true,
    'booking_id', v_booking.id,
    'status',     'CONFIRMED',
    'fixer_id',   v_offer.fixer_id
  );
END;
$$;
