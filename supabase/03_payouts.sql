-- ═══════════════════════════════════════════════════════════════
-- create_payout + release_due_payouts
-- Fixed for actual schema (fixers, bookings.fixer_id/customer_id/amount)
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION create_payout(
  p_booking_id     UUID,
  p_commission_pct NUMERIC DEFAULT 15.0
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

-- ═══════════════════════════════════════════════════════════════
-- release_due_payouts — called by pg_cron every 30 minutes
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION release_due_payouts()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec   RECORD;
  v_total INTEGER := 0;
BEGIN
  FOR v_rec IN
    SELECT p.id AS payout_id, p.fixer_id, p.net_amount, p.booking_id,
           b.status AS booking_status
    FROM   payouts p
    JOIN   bookings b ON b.id = p.booking_id
    WHERE  p.status    = 'held'
      AND  p.hold_until <= now()
      AND  b.status   != 'DISPUTED'
    FOR UPDATE OF p SKIP LOCKED
  LOOP
    UPDATE payouts SET
      status      = 'released',
      released_at = now(),
      updated_at  = now()
    WHERE id = v_rec.payout_id;

    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT
      f.user_id,
      '✅ Payment released',
      'Your payment of R' || v_rec.net_amount::TEXT || ' has been released.',
      'payout_released',
      v_rec.booking_id
    FROM fixers f WHERE f.id = v_rec.fixer_id;

    v_total := v_total + 1;
  END LOOP;

  RETURN v_total;
END;
$$;
