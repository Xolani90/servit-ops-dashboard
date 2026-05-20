-- ═══════════════════════════════════════════════════════════════
-- activate_scheduled_bookings
-- Called by cron job every 5 minutes.
-- Finds paid scheduled bookings whose start window is within 2 hours
-- and triggers matching for them.
--
-- FIX #9 (critical): The previous version queried
--   status = 'CREATED' AND payment_status = 'paid'
-- This state is IMPOSSIBLE. The flow is:
--   create_booking        → status=CREATED,   payment_status=pending
--   create_payment_session→ status=PENDING_PAYMENT, payment_status=pending
--   process_yoco_payment  → status=SEARCHING, payment_status=paid
-- So a booking that has been paid is always in SEARCHING (or later),
-- never in CREATED. The cron was a no-op — it matched zero rows.
--
-- The correct state for a paid scheduled booking waiting for activation
-- is status='SEARCHING' with current_offer_id IS NULL and
-- match_fixers() returning early because scheduled_for > now()+2h.
-- This function is now the explicit activation signal that tells
-- match_fixers() the window has opened. We filter to bookings in
-- SEARCHING state with scheduled_for between now() and now()+2h.
--
-- FIX #10 (minor): RETURN v_count was returning only the last
-- iteration's GET DIAGNOSTICS count, not the total activations.
-- Changed to use a dedicated v_total counter.
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION activate_scheduled_bookings()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking RECORD;
  v_rows    INTEGER;
  v_total   INTEGER := 0;   -- FIX #10: total count, not last-iteration count
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  -- FIX #9: Look for SEARCHING (not CREATED) paid scheduled bookings
  --         whose start time is now within the 2-hour activation window.
  --         We also guard current_offer_id IS NULL to avoid re-triggering
  --         bookings that are already OFFERED and waiting on a fixer.
  FOR v_booking IN
    SELECT id
    FROM   bookings
    WHERE  booking_mode     = 'scheduled'
      AND  status           = 'SEARCHING'          -- FIX: was 'CREATED'
      AND  payment_status   = 'paid'
      AND  current_offer_id IS NULL                -- no active offer yet
      AND  scheduled_for    <= now() + interval '2 hours'
      AND  scheduled_for    > now()
    FOR UPDATE SKIP LOCKED                         -- safe for concurrent runs
  LOOP
    -- Attempt matching — match_fixers() will succeed now that
    -- scheduled_for is within the 2-hour window.
    PERFORM match_fixers(v_booking.id);

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    -- match_fixers is a SELECT … RETURNING, not an UPDATE, so ROW_COUNT
    -- here is always 1 (the SELECT). Use the presence of no error as success.
    v_total := v_total + 1;

    INSERT INTO booking_events (
      booking_id,
      event_type,
      metadata
    ) VALUES (
      v_booking.id,
      'scheduled_activation_triggered',
      jsonb_build_object('triggered_at', now())
    );
  END LOOP;

  RETURN v_total;   -- FIX #10: return total, not last-iteration count
END;
$$;
