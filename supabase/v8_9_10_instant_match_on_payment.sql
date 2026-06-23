-- ═══════════════════════════════════════════════════════════════════════════
-- SERVIT v8.9.10 — Instant matching on payment + 90-second offer window
--
-- PROBLEM: Payment goes through → booking flips to SEARCHING → pg_notify
--   fires but nothing is subscribed → retry-matching cron is commented out
--   → only the 5-minute reconcile-searching cron ever triggers matching.
--   Real-world result: 4–7 minute delay before first offer.
--
-- FIX 1 — Instant inline match
--   process_yoco_payment_success() now calls match_fixers() directly after
--   flipping the booking to SEARCHING. Offer fires within the same webhook
--   transaction, zero wait time. If no fixer is available the reconciler
--   still retries on the next cron cycle as before.
--
-- FIX 2 — 90-second offer window (was 45s)
--   match_fixers() offer expiry widened to 90 seconds. SA mobile latency
--   means 45s was too tight — fixers were seeing notifications after offers
--   had already expired.
--
-- FIX 3 — Re-enable the retry-matching cron (every minute)
--   For bookings where the inline call found no fixer, a per-minute cron
--   now populates matching_requests so process_matching_requests() picks
--   them up quickly instead of waiting 5 minutes.
-- ═══════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────
-- PART 1: Update match_fixers() — 90-second window
-- ─────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION match_fixers(
  p_booking_id  UUID,
  p_radius_km   DOUBLE PRECISION DEFAULT 25.0,
  p_batch_size  INTEGER          DEFAULT 3
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking          bookings%ROWTYPE;
  v_fixer            RECORD;
  v_offer_id         UUID;
  v_offer_expires_at TIMESTAMPTZ;
  v_customer_lat     DOUBLE PRECISION;
  v_customer_lng     DOUBLE PRECISION;
  v_customer_city    TEXT;
  v_offers_sent      INTEGER := 0;
  v_first_offer_id   UUID;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Booking not found');
  END IF;

  IF v_booking.status != 'SEARCHING' OR v_booking.payment_status != 'paid' THEN
    RETURN jsonb_build_object('error', 'Booking not available for matching');
  END IF;

  -- Scheduled bookings: don't match until 2h before slot
  IF v_booking.booking_mode = 'scheduled'
     AND v_booking.scheduled_for > now() + interval '2 hours' THEN
    RETURN jsonb_build_object('error', 'Scheduled booking not ready for matching');
  END IF;

  v_customer_lat  := v_booking.customer_latitude;
  v_customer_lng  := v_booking.customer_longitude;

  SELECT p.city INTO v_customer_city
  FROM profiles p WHERE p.id = v_booking.customer_id;

  -- FIX 2: 90-second offer window (was 45s)
  v_offer_expires_at := now() + interval '90 seconds';

  FOR v_fixer IN
    SELECT f.*
    FROM fixers f
    WHERE f.status    = 'approved'
      AND f.available = true
      AND f.last_seen_at >= now() - interval '8 minutes'
      AND (
        (
          f.latitude IS NOT NULL
          AND f.longitude IS NOT NULL
          AND v_customer_lat IS NOT NULL
          AND v_customer_lng IS NOT NULL
          AND (
            2 * 6371 * asin(sqrt(
              power(sin(radians((f.latitude  - v_customer_lat)  / 2)), 2) +
              cos(radians(v_customer_lat)) *
              cos(radians(f.latitude)) *
              power(sin(radians((f.longitude - v_customer_lng) / 2)), 2)
            ))
          ) <= p_radius_km
        )
        OR
        (
          (v_customer_lat IS NULL OR v_customer_lng IS NULL OR f.latitude IS NULL OR f.longitude IS NULL)
          AND f.city = v_customer_city
        )
      )
      AND (
        v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (
          SELECT 1 FROM fixer_categories fc
          WHERE fc.fixer_id = f.id AND fc.category = v_booking.category
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM offers o
        WHERE  o.booking_id = v_booking.id
          AND  o.fixer_id   = f.id
          AND  o.status     IN ('declined', 'expired')
      )
    ORDER BY
      CASE WHEN f.acceptance_rate < 60 THEN 1 ELSE 0 END ASC,
      CASE
        WHEN f.latitude IS NOT NULL AND f.longitude IS NOT NULL
             AND v_customer_lat IS NOT NULL AND v_customer_lng IS NOT NULL
        THEN
          2 * 6371 * asin(sqrt(
            power(sin(radians((f.latitude  - v_customer_lat)  / 2)), 2) +
            cos(radians(v_customer_lat)) *
            cos(radians(f.latitude)) *
            power(sin(radians((f.longitude - v_customer_lng) / 2)), 2)
          ))
        ELSE 0
      END ASC,
      f.rating DESC,
      f.jobs_completed ASC
    LIMIT p_batch_size
  LOOP
    INSERT INTO offers (booking_id, fixer_id, expires_at)
    VALUES (v_booking.id, v_fixer.id, v_offer_expires_at)
    ON CONFLICT (booking_id, fixer_id) DO NOTHING
    RETURNING id INTO v_offer_id;

    IF v_offer_id IS NOT NULL THEN
      v_offers_sent := v_offers_sent + 1;

      IF v_first_offer_id IS NULL THEN
        v_first_offer_id := v_offer_id;
      END IF;

      INSERT INTO notifications (user_id, title, body, type, related_id)
      VALUES (
        v_fixer.user_id,
        '🔔 New job offer!',
        'A client needs help' ||
          COALESCE(' (' || v_booking.category || ')', '') ||
          '. Accept within 90 seconds.',
        'job_offer',
        v_offer_id
      );

      INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata)
      VALUES (
        v_booking.id, 'offer_created', 'SEARCHING', 'OFFERED',
        jsonb_build_object(
          'fixer_id',       v_fixer.id,
          'offer_id',       v_offer_id,
          'match_method',   CASE WHEN v_customer_lat IS NOT NULL THEN 'geo' ELSE 'city_text' END,
          'batch_position', v_offers_sent
        )
      );
    END IF;
  END LOOP;

  IF v_offers_sent = 0 THEN
    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT
      f.user_id,
      '💼 Job available near you!',
      'A client needs help' ||
        COALESCE(' (' || v_booking.category || ')', '') ||
        COALESCE(' in ' || v_customer_city, ' in your area') ||
        '. Go online to accept.',
      'demand_alert',
      v_booking.id
    FROM fixers f
    WHERE f.status = 'approved'
      AND f.city = v_customer_city
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE  n.user_id    = f.user_id
          AND  n.related_id = v_booking.id
          AND  n.type       = 'demand_alert'
      );

    PERFORM pg_notify(
      'demand_alert',
      jsonb_build_object('booking_id', v_booking.id, 'city', v_customer_city)::text
    );

    RETURN jsonb_build_object(
      'error',      'No fixers available',
      'broadcast',  true,
      'booking_id', v_booking.id
    );
  END IF;

  UPDATE bookings SET
    status           = 'OFFERED',
    offered_at       = now(),
    current_offer_id = v_first_offer_id,
    offer_expires_at = v_offer_expires_at,
    updated_at       = now(),
    version          = version + 1
  WHERE id = v_booking.id;

  RETURN jsonb_build_object(
    'success',      true,
    'booking_id',   v_booking.id,
    'status',       'OFFERED',
    'offers_sent',  v_offers_sent,
    'expires_at',   v_offer_expires_at
  );
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────
-- PART 2: Update process_yoco_payment_success() — inline immediate match
-- ─────────────────────────────────────────────────────────────────────────

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
  v_booking      bookings%ROWTYPE;
  v_payment      payments%ROWTYPE;
  v_match_result JSONB;
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

  -- Only reject genuine underpayment / fraud; accept venue overpayment
  IF p_amount < (v_payment.amount - 0.01) THEN
    RAISE EXCEPTION 'Underpayment: expected at least %, got %', v_payment.amount, p_amount;
  END IF;

  -- Validate booking is in correct state for payment
  IF v_booking.payment_status != 'pending' OR v_booking.status NOT IN ('CREATED', 'PENDING_PAYMENT') THEN
    RAISE EXCEPTION 'Booking % not ready for payment confirmation', v_booking.id;
  END IF;

  -- Update payment
  UPDATE payments SET
    status               = 'paid',
    provider_payment_id  = p_provider_payment_id,
    amount_captured      = p_amount,
    verified_at          = now(),
    updated_at           = now()
  WHERE id = p_payment_id;

  -- Update booking to SEARCHING
  UPDATE bookings SET
    payment_status       = 'paid',
    payment_reference    = p_provider_payment_id,
    payment_confirmed_at = now(),
    status               = 'SEARCHING',
    updated_at           = now(),
    version              = version + 1
  WHERE id = v_booking.id
  RETURNING * INTO v_booking;

  -- Audit event
  INSERT INTO booking_events (
    booking_id, event_type, old_status, new_status, metadata
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

  -- FIX 1: Immediate inline match — no queue, no cron wait.
  -- match_fixers() runs synchronously right now. If a fixer is online the
  -- offer is created before this function even returns. If no fixer is
  -- available it returns early with error:'No fixers available', and the
  -- retry-matching cron picks it up within 1 minute.
  SELECT match_fixers(v_booking.id, 25.0, 3) INTO v_match_result;

  -- Keep pg_notify for any future Edge Function subscriber
  PERFORM pg_notify(
    'booking_paid',
    jsonb_build_object(
      'booking_id',   v_booking.id,
      'match_result', v_match_result
    )::text
  );

  RETURN jsonb_build_object(
    'success',          true,
    'booking_id',       v_booking.id,
    'status',           v_booking.status,
    'amount_captured',  p_amount,
    'amount_service',   v_payment.amount,
    'match_result',     v_match_result
  );
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────
-- PART 3: Re-enable retry-matching cron (every 1 minute)
-- For the "no fixer available at payment time" case — keeps retrying until
-- a fixer comes online, expanding radius each pass.
-- ─────────────────────────────────────────────────────────────────────────

-- Drop the old disabled version first
SELECT cron.unschedule('retry-matching') WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'retry-matching'
);

SELECT cron.schedule(
  'retry-matching',
  '* * * * *',
  $$
    INSERT INTO matching_requests (
      booking_id, requested_by, priority, radius_km, batch_size, metadata
    )
    SELECT
      b.id,
      'retry-cron' AS requested_by,
      5            AS priority,
      LEAST(70.0, 25.0 + (
        SELECT COUNT(*)::DOUBLE PRECISION * 15.0
        FROM   booking_events be
        WHERE  be.booking_id  = b.id
          AND  be.event_type IN ('offer_created', 'match_attempt')
      )) AS radius_km,
      3 AS batch_size,
      jsonb_build_object('source', 'retry-cron') AS metadata
    FROM bookings b
    WHERE  b.status         = 'SEARCHING'
      AND  b.payment_status = 'paid'
      AND  b.created_at     < now() - interval '30 seconds'
      AND  (b.booking_mode = 'asap'
            OR (b.booking_mode = 'scheduled' AND b.scheduled_for <= now() + interval '2 hours'))
      AND  NOT EXISTS (
        SELECT 1 FROM matching_requests mr
        WHERE  mr.booking_id = b.id AND mr.processed = false
      );

    SELECT process_matching_requests();
  $$
);


-- ─────────────────────────────────────────────────────────────────────────
-- PART 4: Immediate run — clear anything stuck right now
-- ─────────────────────────────────────────────────────────────────────────

INSERT INTO matching_requests (
  booking_id, requested_by, priority, radius_km, batch_size, metadata
)
SELECT
  b.id,
  'v8.9.10-migration' AS requested_by,
  10                  AS priority,
  25.0                AS radius_km,
  3                   AS batch_size,
  jsonb_build_object('source', 'migration-catchup') AS metadata
FROM bookings b
WHERE  b.status         = 'SEARCHING'
  AND  b.payment_status = 'paid'
  AND  NOT EXISTS (
    SELECT 1 FROM matching_requests mr
    WHERE  mr.booking_id = b.id AND mr.processed = false
  );

SELECT process_matching_requests();


-- ─────────────────────────────────────────────────────────────────────────
-- PART 5: Verification
-- ─────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_def TEXT;
BEGIN
  -- Confirm match_fixers has 90-second window
  SELECT prosrc INTO v_def FROM pg_proc WHERE proname = 'match_fixers' LIMIT 1;
  IF v_def NOT LIKE '%90 seconds%' THEN
    RAISE EXCEPTION 'match_fixers() was not updated to 90-second window';
  END IF;

  -- Confirm payment function calls match_fixers inline
  SELECT prosrc INTO v_def FROM pg_proc WHERE proname = 'process_yoco_payment_success' LIMIT 1;
  IF v_def NOT LIKE '%match_fixers%' THEN
    RAISE EXCEPTION 'process_yoco_payment_success() is missing inline match_fixers call';
  END IF;

  RAISE NOTICE '✅ v8.9.10 verified: instant match on payment, 90-second offer window, retry cron active';
END;
$$;
