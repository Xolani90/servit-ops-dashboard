-- ═══════════════════════════════════════════════════════════════
-- create_booking — v5.2
-- FIX 1: Added p_category parameter so bookings.category is
--         populated at creation time. match_fixers() category
--         filter now works correctly.
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION create_booking(
  p_customer_id      UUID,
  p_description      TEXT,
  p_address          TEXT,
  p_customer_phone   TEXT,
  p_amount           NUMERIC,
  p_booking_mode     booking_mode_enum DEFAULT 'asap',
  p_scheduled_for    TIMESTAMPTZ       DEFAULT NULL,
  p_customer_lat     DOUBLE PRECISION  DEFAULT NULL,
  p_customer_lng     DOUBLE PRECISION  DEFAULT NULL,
  p_category         TEXT              DEFAULT NULL   -- FIX v5.2
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking_id    UUID;
  v_recent_count  INTEGER;
  v_result        JSONB;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  -- Rate limiting: max 3 active bookings per customer per hour
  SELECT COUNT(*) INTO v_recent_count
  FROM   bookings
  WHERE  customer_id = p_customer_id
    AND  created_at  >= now() - INTERVAL '1 hour'
    AND  status      NOT IN ('CANCELLED', 'EXPIRED', 'COMPLETED');

  IF v_recent_count >= 3 THEN
    RAISE EXCEPTION 'Rate limit: you can only create 3 bookings per hour.';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than 0';
  END IF;

  IF p_booking_mode = 'scheduled' AND p_scheduled_for IS NULL THEN
    RAISE EXCEPTION 'scheduled_for required for scheduled bookings';
  END IF;

  IF p_address IS NULL OR length(trim(p_address)) < 5 THEN
    RAISE EXCEPTION 'Valid address required';
  END IF;

  INSERT INTO bookings (
    customer_id,
    description,
    address,
    customer_phone,
    amount,
    booking_mode,
    scheduled_for,
    status,
    payment_status,
    customer_latitude,
    customer_longitude,
    category          -- FIX v5.2: populate category for match_fixers()
  ) VALUES (
    p_customer_id,
    p_description,
    p_address,
    p_customer_phone,
    p_amount,
    p_booking_mode,
    p_scheduled_for,
    'CREATED',
    'pending',
    p_customer_lat,
    p_customer_lng,
    p_category
  )
  RETURNING id INTO v_booking_id;

  INSERT INTO booking_events (booking_id, event_type, new_status, created_by, metadata)
  VALUES (
    v_booking_id,
    'booking_created',
    'CREATED',
    p_customer_id,
    jsonb_build_object(
      'has_coordinates', (p_customer_lat IS NOT NULL),
      'match_method',    CASE WHEN p_customer_lat IS NOT NULL THEN 'haversine' ELSE 'city_text' END,
      'category',        p_category
    )
  );

  SELECT jsonb_build_object(
    'booking_id',      id,
    'status',          status,
    'payment_status',  payment_status,
    'amount',          amount,
    'booking_mode',    booking_mode,
    'category',        category,
    'has_coordinates', (customer_latitude IS NOT NULL)
  ) INTO v_result
  FROM bookings WHERE id = v_booking_id;

  RETURN v_result;
END;
$$;


-- ═══════════════════════════════════════════════════════════════
-- mark_payment_refunded — v5.2
-- FIX 2 (Issue 1): The old version inserted
--   old_status = 'paid' / new_status = 'refunded' into booking_events.
--   Both columns are typed booking_status_enum. 'paid' and 'refunded'
--   are payment_status_enum values — the cast threw a Postgres type
--   error at runtime. Yoco refund succeeded but the DB never recorded
--   it, creating double-refund risk on retry.
--
-- FIX: old_status and new_status are set to NULL (they are booking
--   state columns, not payment state columns). Payment state change
--   is stored in metadata JSONB instead.
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION mark_payment_refunded(
  p_booking_id UUID,
  p_payment_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_customer_id UUID;
BEGIN
  -- Idempotency guard: only mark as refunded if currently paid
  UPDATE payments
  SET    status     = 'refunded',
         updated_at = now()
  WHERE  id         = p_payment_id
    AND  booking_id = p_booking_id
    AND  status     = 'paid';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('message', 'Payment already refunded or not found');
  END IF;

  SELECT customer_id INTO v_customer_id
  FROM   bookings
  WHERE  id = p_booking_id;

  -- FIX: use NULL for booking status columns; store payment state in metadata
  INSERT INTO booking_events (
    booking_id, event_type, old_status, new_status, metadata, created_by
  ) VALUES (
    p_booking_id,
    'payment_refunded',
    NULL,   -- not a booking status transition
    NULL,   -- not a booking status transition
    jsonb_build_object(
      'payment_id',          p_payment_id,
      'payment_old_status',  'paid',
      'payment_new_status',  'refunded'
    ),
    v_customer_id
  );

  RETURN jsonb_build_object('success', true, 'payment_id', p_payment_id);
END;
$$;


-- ═══════════════════════════════════════════════════════════════
-- toggle_fixer_availability — v5.2 (no changes from v5.1)
-- Included here for completeness — this is the canonical version.
-- ═══════════════════════════════════════════════════════════════

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


-- ═══════════════════════════════════════════════════════════════
-- platform_commission_pct — single source of truth (v5.1, unchanged)
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION platform_commission_pct()
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 12.0;
$$;


-- ═══════════════════════════════════════════════════════════════
-- create_payout — uses platform_commission_pct() (v5.1, unchanged)
-- ═══════════════════════════════════════════════════════════════

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

  IF EXISTS (SELECT 1 FROM payouts WHERE booking_id = p_booking_id) THEN
    RETURN jsonb_build_object('message', 'Payout already exists');
  END IF;

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
