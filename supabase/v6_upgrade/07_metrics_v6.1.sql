-- ═══════════════════════════════════════════════════════════════
-- SERVIT v6.1 — PATCH 3: Fixer Performance Metrics
-- Adds: completion_rate, avg_response_time (already have acceptance_rate)
-- Updates metrics after every relevant event
-- ═══════════════════════════════════════════════════════════════

-- ── Add missing metric columns ────────────────────────────────
ALTER TABLE fixers
  ADD COLUMN IF NOT EXISTS completion_rate     NUMERIC(5,2) DEFAULT 100.0,  -- % of accepted jobs completed
  ADD COLUMN IF NOT EXISTS avg_response_time   INTEGER,                      -- seconds (alias response_time_avg)
  ADD COLUMN IF NOT EXISTS total_offers_sent   INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_accepted       INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_completed      INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_cancelled      INTEGER NOT NULL DEFAULT 0;  -- fixer-side cancels

-- Sync response_time_avg → avg_response_time (keep both names consistent)
UPDATE fixers SET avg_response_time = response_time_avg WHERE avg_response_time IS NULL AND response_time_avg IS NOT NULL;

-- ── Core metric update function ───────────────────────────────
CREATE OR REPLACE FUNCTION update_fixer_metrics(p_fixer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offers_sent   INTEGER;
  v_accepted      INTEGER;
  v_completed     INTEGER;
  v_cancelled     INTEGER;
  v_avg_response  NUMERIC;
  v_acc_rate      NUMERIC;
  v_comp_rate     NUMERIC;
BEGIN
  -- Count from offers table
  SELECT
    COUNT(*) FILTER (WHERE status IN ('accepted','expired','declined')),
    COUNT(*) FILTER (WHERE status = 'accepted')
  INTO v_offers_sent, v_accepted
  FROM offers WHERE fixer_id = p_fixer_id;

  -- Count from bookings
  SELECT
    COUNT(*) FILTER (WHERE status = 'COMPLETED'),
    COUNT(*) FILTER (WHERE status = 'CANCELLED'
      AND EXISTS (
        SELECT 1 FROM booking_events be
        WHERE be.booking_id = bookings.id
          AND be.event_type = 'fixer_cancelled'
      ))
  INTO v_completed, v_cancelled
  FROM bookings WHERE fixer_id = p_fixer_id;

  -- Acceptance rate: accepted / offers_sent
  v_acc_rate := CASE WHEN v_offers_sent > 0
    THEN ROUND((v_accepted::NUMERIC / v_offers_sent) * 100, 1)
    ELSE 100.0 END;

  -- Completion rate: completed / accepted
  v_comp_rate := CASE WHEN v_accepted > 0
    THEN ROUND((v_completed::NUMERIC / v_accepted) * 100, 1)
    ELSE 100.0 END;

  -- Avg response time from dispatch_log (seconds)
  SELECT AVG(EXTRACT(EPOCH FROM (responded_at - notified_at)))::INTEGER
  INTO v_avg_response
  FROM dispatch_log
  WHERE fixer_id = p_fixer_id AND status = 'accepted' AND responded_at IS NOT NULL;

  UPDATE fixers SET
    total_offers_sent  = v_offers_sent,
    total_accepted     = v_accepted,
    total_completed    = v_completed,
    total_cancelled    = v_cancelled,
    acceptance_rate    = v_acc_rate::INTEGER,
    completion_rate    = v_comp_rate,
    avg_response_time  = v_avg_response,
    response_time_avg  = v_avg_response,  -- keep v6.0 column in sync
    jobs_completed     = v_completed,
    updated_at         = now()
  WHERE id = p_fixer_id;
END;
$$;

-- ── Updated accept_offer: records response time + marks busy ──
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
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT user_id INTO v_verify_owner FROM fixers WHERE id = p_fixer_id;
  IF v_verify_owner IS NULL OR v_verify_owner != p_fixer_user_id THEN
    RAISE EXCEPTION 'Unauthorized: fixer does not own this offer';
  END IF;

  SELECT * INTO v_offer FROM offers WHERE id = p_offer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Offer not found'; END IF;
  IF v_offer.status != 'pending' THEN RAISE EXCEPTION 'Offer already %', v_offer.status; END IF;
  IF v_offer.expires_at < now() THEN
    UPDATE offers SET status = 'expired' WHERE id = p_offer_id;
    RAISE EXCEPTION 'Offer has expired';
  END IF;

  SELECT * INTO v_booking FROM bookings WHERE id = v_offer.booking_id FOR UPDATE;
  IF v_booking.status NOT IN ('OFFERED','SEARCHING') THEN
    RAISE EXCEPTION 'Booking not in dispatchable state (current: %)', v_booking.status;
  END IF;

  -- Record response time
  SELECT notified_at INTO v_dispatch_time
  FROM dispatch_log
  WHERE booking_id = v_offer.booking_id AND fixer_id = p_fixer_id
  ORDER BY created_at DESC LIMIT 1;

  IF v_dispatch_time IS NOT NULL THEN
    v_response_secs := EXTRACT(EPOCH FROM (now() - v_dispatch_time))::INTEGER;
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

  -- Mark fixer busy (v6.0 function)
  PERFORM mark_fixer_busy(v_offer.fixer_id);

  -- Update dispatch log
  UPDATE dispatch_log SET
    status       = 'accepted',
    responded_at = now()
  WHERE booking_id = v_offer.booking_id
    AND fixer_id   = p_fixer_id
    AND status     = 'notified';

  -- Expire other pending offers
  FOR v_losing_fixer IN
    SELECT o.id AS offer_id, f.user_id AS fixer_user_id
    FROM   offers o JOIN fixers f ON f.id = o.fixer_id
    WHERE  o.booking_id = v_booking.id
      AND  o.id        != p_offer_id
      AND  o.status     = 'pending'
    FOR UPDATE OF o SKIP LOCKED
  LOOP
    UPDATE offers SET status = 'expired', responded_at = now() WHERE id = v_losing_fixer.offer_id;
    INSERT INTO notifications (user_id, title, body, type, related_id)
    VALUES (v_losing_fixer.fixer_user_id,'⚡ Job taken',
      'Another fixer accepted this job first. Stay available!','offer_expired',v_booking.id);
  END LOOP;

  INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata, created_by)
  VALUES (v_booking.id, 'offer_accepted', 'OFFERED', 'CONFIRMED',
    jsonb_build_object(
      'offer_id',       p_offer_id,
      'fixer_id',       v_offer.fixer_id,
      'response_secs',  v_response_secs
    ), p_fixer_user_id);

  -- Async metric update (non-blocking via notify)
  PERFORM pg_notify('update_metrics', p_fixer_id::TEXT);

  RETURN jsonb_build_object(
    'success',        true,
    'booking_id',     v_booking.id,
    'status',         'CONFIRMED',
    'fixer_id',       v_offer.fixer_id,
    'response_secs',  v_response_secs
  );
END;
$$;

-- ── Trigger: update metrics after booking completes/cancels ───
CREATE OR REPLACE FUNCTION trigger_update_fixer_metrics()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IN ('COMPLETED','CANCELLED')
     AND OLD.status NOT IN ('COMPLETED','CANCELLED')
     AND NEW.fixer_id IS NOT NULL THEN
    PERFORM update_fixer_metrics(NEW.fixer_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_update_fixer_metrics ON bookings;
CREATE TRIGGER trg_update_fixer_metrics
  AFTER UPDATE ON bookings
  FOR EACH ROW
  EXECUTE FUNCTION trigger_update_fixer_metrics();

GRANT EXECUTE ON FUNCTION update_fixer_metrics(UUID)  TO service_role;
GRANT EXECUTE ON FUNCTION accept_offer(UUID,UUID,UUID) TO authenticated;
