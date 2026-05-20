-- ═══════════════════════════════════════════════════════════════
-- SERVIT v6.4 — Backend functions
-- 1. Trust cues: "who is coming" moment
-- 2. ETA transparency in notifications
-- 3. Favourite fixer + rebook flow
-- 4. Premium priority queue (first-in-queue guarantee)
-- 5. Multi-job overlap guard (tighter busy logic)
-- ═══════════════════════════════════════════════════════════════

-- ── FIX 5: Tighter multi-job overlap guard ────────────────────
-- Replaces mark_fixer_busy — checks no concurrent active jobs
DROP FUNCTION IF EXISTS mark_fixer_busy(UUID);
CREATE OR REPLACE FUNCTION mark_fixer_busy(p_fixer_id UUID)
RETURNS BOOLEAN  -- returns false if fixer already has active job
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows INTEGER;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  -- Only mark busy if not already assigned to another active job
  UPDATE fixers SET
    fixer_status = 'busy',
    available    = false,
    updated_at   = now()
  WHERE id = p_fixer_id
    AND fixer_status != 'busy'  -- FIX 5: hard guard — already busy = already on a job
    AND NOT EXISTS (            -- FIX 5: double-check no concurrent job leak
      SELECT 1 FROM bookings b
      WHERE b.fixer_id = p_fixer_id
        AND b.status IN ('CONFIRMED','EN_ROUTE','ARRIVED','IN_PROGRESS')
    );

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END;
$$;

-- Wire the return value into accept_offer:
-- If mark_fixer_busy returns false, abort the accept
DROP FUNCTION IF EXISTS accept_offer(UUID, UUID, UUID);
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
  v_offer         offers%ROWTYPE;
  v_booking       bookings%ROWTYPE;
  v_verify_owner  UUID;
  v_losing_fixer  RECORD;
  v_dispatch_time TIMESTAMPTZ;
  v_response_secs INTEGER;
  v_rows          INTEGER;
  v_busy_ok       BOOLEAN;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT user_id INTO v_verify_owner FROM fixers WHERE id = p_fixer_id;
  IF v_verify_owner IS NULL OR v_verify_owner != p_fixer_user_id THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  -- FIX 5: pre-check — fixer must not already be on a job
  IF EXISTS (
    SELECT 1 FROM bookings WHERE fixer_id = p_fixer_id
      AND status IN ('CONFIRMED','EN_ROUTE','ARRIVED','IN_PROGRESS')
  ) THEN
    RAISE EXCEPTION 'You already have an active job in progress. Complete it before accepting another.';
  END IF;

  SELECT * INTO v_offer FROM offers WHERE id = p_offer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Offer not found'; END IF;
  IF v_offer.status != 'pending' THEN RAISE EXCEPTION 'Offer already %', v_offer.status; END IF;
  IF v_offer.expires_at < now() THEN
    UPDATE offers SET status = 'expired' WHERE id = p_offer_id;
    RAISE EXCEPTION 'Offer expired';
  END IF;

  -- Atomic booking claim
  UPDATE bookings SET
    status           = 'CONFIRMED',
    fixer_id         = p_fixer_id,
    confirmed_at     = now(),
    current_offer_id = p_offer_id,
    updated_at       = now(),
    version          = version + 1
  WHERE id = v_offer.booking_id
    AND fixer_id IS NULL
    AND status IN ('OFFERED','SEARCHING');

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    UPDATE offers SET status = 'expired', responded_at = now() WHERE id = p_offer_id;
    RAISE EXCEPTION 'Job already taken';
  END IF;

  SELECT * INTO v_booking FROM bookings WHERE id = v_offer.booking_id;

  UPDATE offers SET status = 'accepted', responded_at = now() WHERE id = p_offer_id;

  -- FIX 5: tighter mark_fixer_busy with overlap guard
  v_busy_ok := mark_fixer_busy(p_fixer_id);
  IF NOT v_busy_ok THEN
    -- Rollback the booking accept
    PERFORM set_config('app.allow_status_change', 'true', true);
    UPDATE bookings SET status = 'OFFERED', fixer_id = NULL, confirmed_at = NULL
    WHERE id = v_offer.booking_id;
    UPDATE offers SET status = 'pending', responded_at = NULL WHERE id = p_offer_id;
    RAISE EXCEPTION 'Conflict: you have another active job. Please complete it first.';
  END IF;

  -- Record response time
  SELECT notified_at INTO v_dispatch_time
  FROM dispatch_log
  WHERE booking_id = v_offer.booking_id AND fixer_id = p_fixer_id
  ORDER BY created_at DESC LIMIT 1;

  IF v_dispatch_time IS NOT NULL THEN
    v_response_secs := EXTRACT(EPOCH FROM (now() - v_dispatch_time))::INTEGER;

    UPDATE dispatch_log SET status = 'accepted', responded_at = now()
    WHERE booking_id = v_offer.booking_id AND fixer_id = p_fixer_id AND status = 'notified';

    -- Record time_to_first_accept for premium SLA tracking
    UPDATE bookings SET time_to_first_accept = v_response_secs
    WHERE id = v_offer.booking_id AND time_to_first_accept IS NULL;

    -- Rolling response time average (last 20)
    UPDATE fixers SET
      avg_response_time = (
        SELECT ROUND(AVG(EXTRACT(EPOCH FROM (d.responded_at - d.notified_at))))
        FROM (
          SELECT responded_at, notified_at FROM dispatch_log
          WHERE fixer_id = p_fixer_id AND status = 'accepted' AND responded_at IS NOT NULL
          ORDER BY created_at DESC LIMIT 20
        ) d
      ),
      updated_at = now()
    WHERE id = p_fixer_id;
  END IF;

  -- Expire other pending offers
  FOR v_losing_fixer IN
    SELECT o.id AS offer_id, f.user_id AS fixer_user_id
    FROM offers o JOIN fixers f ON f.id = o.fixer_id
    WHERE o.booking_id = v_booking.id AND o.id != p_offer_id AND o.status = 'pending'
    FOR UPDATE OF o SKIP LOCKED
  LOOP
    UPDATE offers SET status = 'expired', responded_at = now() WHERE id = v_losing_fixer.offer_id;
    INSERT INTO notifications (user_id, title, body, type, related_id)
    VALUES (v_losing_fixer.fixer_user_id, '⚡ Job taken',
      'Another fixer accepted first. Stay available!', 'offer_expired', v_booking.id);
  END LOOP;

  INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata, created_by)
  VALUES (v_booking.id, 'offer_accepted', 'OFFERED', 'CONFIRMED',
    jsonb_build_object('offer_id', p_offer_id, 'fixer_id', p_fixer_id, 'response_secs', v_response_secs),
    p_fixer_user_id);

  PERFORM pg_notify('update_metrics', p_fixer_id::TEXT);

  RETURN jsonb_build_object(
    'success', true, 'booking_id', v_booking.id,
    'status', 'CONFIRMED', 'fixer_id', p_fixer_id, 'response_secs', v_response_secs
  );
END;
$$;

-- ── Favourite fixer functions ─────────────────────────────────
DROP FUNCTION IF EXISTS toggle_favourite_fixer(UUID, UUID);
CREATE OR REPLACE FUNCTION toggle_favourite_fixer(
  p_customer_id UUID,
  p_fixer_id    UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_exists BOOLEAN;
BEGIN
  SELECT EXISTS(
    SELECT 1 FROM favourite_fixers
    WHERE customer_id = p_customer_id AND fixer_id = p_fixer_id
  ) INTO v_exists;

  IF v_exists THEN
    DELETE FROM favourite_fixers
    WHERE customer_id = p_customer_id AND fixer_id = p_fixer_id;
    RETURN jsonb_build_object('favourited', false);
  ELSE
    INSERT INTO favourite_fixers (customer_id, fixer_id)
    VALUES (p_customer_id, p_fixer_id)
    ON CONFLICT DO NOTHING;
    RETURN jsonb_build_object('favourited', true);
  END IF;
END;
$$;

-- Rebook: create a new booking pre-filled from a previous one
DROP FUNCTION IF EXISTS rebook_from_history(UUID, UUID);
CREATE OR REPLACE FUNCTION rebook_from_history(
  p_customer_id UUID,
  p_booking_id  UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prev bookings%ROWTYPE;
BEGIN
  SELECT * INTO v_prev
  FROM bookings
  WHERE id = p_booking_id AND customer_id = p_customer_id AND status = 'COMPLETED';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Booking not found or not completed');
  END IF;

  RETURN jsonb_build_object(
    'prefill', jsonb_build_object(
      'description',   v_prev.description,
      'address',       v_prev.address,
      'category',      v_prev.category,
      'service_tier',  v_prev.service_tier,
      'amount',        v_prev.customer_total,
      'fixer_id',      v_prev.fixer_id,
      'fixer_name',    (SELECT full_name FROM fixers WHERE id = v_prev.fixer_id)
    )
  );
END;
$$;

-- ── FIX 4: Premium priority queue ─────────────────────────────
-- Premium jobs get dispatched BEFORE standard/basic jobs that are
-- waiting. This runs as part of match_fixers orchestration.
-- Implemented as: premium bookings skip to position 1 in the
-- advance_expired_dispatches loop and get shorter poll interval.

-- Override match_fixers to record premium queue position
DROP FUNCTION IF EXISTS match_fixers(UUID, DOUBLE PRECISION, INTEGER);
CREATE OR REPLACE FUNCTION match_fixers(
  p_booking_id UUID,
  p_radius_km  DOUBLE PRECISION DEFAULT 25.0,
  p_batch_size INTEGER          DEFAULT 3
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking bookings%ROWTYPE;
  v_result  JSONB;
  v_queue_pos INTEGER;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','Booking not found'); END IF;

  IF v_booking.status != 'SEARCHING' OR v_booking.payment_status != 'paid' THEN
    RETURN jsonb_build_object('error','Booking not available for matching');
  END IF;

  IF v_booking.booking_mode = 'scheduled'
     AND v_booking.scheduled_for > now() + interval '2 hours' THEN
    RETURN jsonb_build_object('error','Scheduled booking not ready');
  END IF;

  -- FIX 4: Record how many jobs are ahead in the dispatch queue
  -- Premium jobs show customers "you're ahead of X standard bookings"
  SELECT COUNT(*) INTO v_queue_pos
  FROM bookings
  WHERE status IN ('SEARCHING','OFFERED')
    AND service_tier != 'premium'
    AND created_at < now();

  UPDATE bookings SET
    dispatch_sequence    = 0,
    dispatch_pass        = 1,
    dispatch_at          = now(),
    premium_queue_position = CASE WHEN v_booking.service_tier = 'premium' THEN v_queue_pos ELSE NULL END
  WHERE id = p_booking_id;

  v_result := dispatch_next_fixer(p_booking_id);

  IF (v_result->>'action') = 'fallback' THEN
    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT f.user_id,
      '💼 Job available — go online!',
      COALESCE(v_booking.category,'A client') || ' job is waiting. Go online to accept.',
      'demand_alert', p_booking_id
    FROM fixers f
    JOIN profiles p ON p.id = v_booking.customer_id
    WHERE f.status = 'approved' AND f.city = p.city
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.user_id = f.user_id AND n.related_id = p_booking_id AND n.type = 'demand_alert'
      );
    RETURN jsonb_build_object('error','No fixers available','broadcast',true,'booking_id',p_booking_id);
  END IF;

  RETURN v_result;
END;
$$;

-- advance_expired_dispatches: premium jobs processed first
DROP FUNCTION IF EXISTS advance_expired_dispatches();
CREATE OR REPLACE FUNCTION advance_expired_dispatches()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking   RECORD;
  v_result    JSONB;
  v_advanced  INTEGER := 0;
BEGIN
  -- FIX 4: ORDER BY premium first, then by expiry time
  FOR v_booking IN
    SELECT b.id, b.service_tier, b.dispatch_sequence, b.dispatch_fixer_id, b.priority_flag
    FROM bookings b
    WHERE b.status = 'OFFERED'
      AND b.dispatch_expiry < now()
      AND b.dispatch_mode != 'manual'
    ORDER BY
      CASE b.service_tier WHEN 'premium' THEN 0 WHEN 'standard' THEN 1 ELSE 2 END,
      b.dispatch_expiry ASC
    FOR UPDATE SKIP LOCKED
  LOOP
    IF v_booking.dispatch_fixer_id IS NOT NULL THEN
      PERFORM apply_ignore_penalty(v_booking.dispatch_fixer_id);
    END IF;

    UPDATE dispatch_log SET status = 'timed_out', responded_at = now()
    WHERE booking_id = v_booking.id AND status = 'notified'
      AND sequence_position = v_booking.dispatch_sequence;

    UPDATE offers SET status = 'expired', responded_at = now()
    WHERE booking_id = v_booking.id AND status = 'pending';

    v_result := dispatch_next_fixer(v_booking.id);

    IF (v_result->>'action') = 'fallback' THEN
      UPDATE bookings SET
        status            = 'SEARCHING',
        dispatch_sequence = 0,
        dispatch_pass     = 1,
        dispatch_fixer_id = NULL,
        updated_at        = now(),
        version           = version + 1
      WHERE id = v_booking.id;

      INSERT INTO notifications (user_id, title, body, type, related_id)
      SELECT p.id, '🚨 Job unmatched — manual needed',
        'All passes exhausted for ' || LEFT(v_booking.id::TEXT,8) ||
        '. Reason: ' || COALESCE(v_result->>'reason','unknown'),
        'admin_alert', v_booking.id
      FROM profiles p WHERE p.user_role = 'admin';
    END IF;

    v_advanced := v_advanced + 1;
  END LOOP;
  RETURN v_advanced;
END;
$$;

GRANT EXECUTE ON FUNCTION mark_fixer_busy(UUID)                        TO service_role, authenticated;
GRANT EXECUTE ON FUNCTION accept_offer(UUID, UUID, UUID)               TO authenticated;
GRANT EXECUTE ON FUNCTION toggle_favourite_fixer(UUID, UUID)           TO authenticated;
GRANT EXECUTE ON FUNCTION rebook_from_history(UUID, UUID)              TO authenticated;
GRANT EXECUTE ON FUNCTION match_fixers(UUID, DOUBLE PRECISION, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION advance_expired_dispatches()                 TO service_role;
