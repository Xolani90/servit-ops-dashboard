-- ═══════════════════════════════════════════════════════════════
-- expire_offers
-- Called by pg_cron job every 10 seconds.
-- Marks expired pending offers and resets bookings to SEARCHING.
--
-- PERFORMANCE FIX: Replaced FOR LOOP row-by-row updates with set-based
-- UPDATE to prevent lock contention under load. All operations are now batched.
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION expire_offers()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total INTEGER;
BEGIN
  -- Set-based UPDATE: expire all pending offers
  WITH expired_offers AS (
    SELECT o.id AS offer_id, o.booking_id, o.fixer_id, f.user_id AS fixer_user_id
    FROM offers o
    JOIN fixers f ON f.id = o.fixer_id
    WHERE o.status = 'pending'
      AND o.expires_at < now()
    FOR UPDATE OF o SKIP LOCKED
  )
  UPDATE offers o
  SET status = 'expired',
      responded_at = now()
  FROM expired_offers eo
  WHERE o.id = eo.offer_id;

  -- Set-based UPDATE: reset bookings to SEARCHING
  WITH affected_bookings AS (
    SELECT DISTINCT eo.booking_id
    FROM expired_offers eo
    JOIN bookings b ON b.id = eo.booking_id
    WHERE b.status = 'OFFERED'
      AND b.current_offer_id = eo.offer_id
  )
  UPDATE bookings b
  SET
    status = 'SEARCHING',
    current_offer_id = NULL,
    offer_expires_at = NULL,
    updated_at = now(),
    version = version + 1
  FROM affected_bookings ab
  WHERE b.id = ab.booking_id;

  GET DIAGNOSTICS v_total = ROW_COUNT;

  -- Set-based INSERT: log booking events for all affected bookings
  INSERT INTO booking_events (
    booking_id,
    event_type,
    old_status,
    new_status,
    metadata
  )
  SELECT
    eo.booking_id,
    'offer_expired',
    'OFFERED',
    'SEARCHING',
    jsonb_build_object('offer_id', eo.offer_id)
  FROM expired_offers eo
  JOIN bookings b ON b.id = eo.booking_id
  WHERE b.status = 'SEARCHING'
    AND b.updated_at = now();

  -- Set-based INSERT: notify fixers about expired offers
  INSERT INTO notifications (user_id, title, body, type, related_id)
  SELECT
    eo.fixer_user_id,
    '⏰ Offer expired',
    'The job offer has expired. Stay available for the next one!',
    'offer_expired',
    eo.booking_id
  FROM expired_offers eo;

  -- Trigger rematch for all affected bookings (batched)
  IF v_total > 0 THEN
    PERFORM pg_notify(
      'booking_paid',
      jsonb_build_object('booking_id', ab.booking_id)::text
    )
    FROM affected_bookings ab;

    -- Direct rematch call for zero-latency retry
    PERFORM match_fixers(ab.booking_id)
    FROM affected_bookings ab;
  END IF;

  RETURN v_total;
END;
$$;
