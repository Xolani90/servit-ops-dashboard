-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8.8 — Critical Cron & Status-Guard Fixes
-- Run AFTER v8_7_assignment_safety.sql
-- Idempotent — safe to re-run.
--
-- Bugs fixed in this file:
--
--  BUG 1 (expire-offers cron uses 6-field seconds syntax)
--    '*/10 * * * * *' is invalid on Supabase pg_cron (5-field only).
--    This caused expire_offers() to NEVER run — pending offers never
--    expired and bookings were permanently stuck in OFFERED, never
--    reset to SEARCHING for the next fixer round.
--    FIX: Re-schedule with valid 5-field syntax '* * * * *' (every
--    minute is the minimum on Supabase). expire_offers() itself calls
--    match_fixers() directly after resetting each booking so the
--    re-match is immediate.
--
--  BUG 2 (expire-pending-payments cron bypasses status-change guard)
--    The original cron job did a raw UPDATE on bookings.status without
--    first setting app.allow_status_change = 'true'. The trigger
--    prevent_booking_status_update fires on every status change and
--    throws "Direct booking status changes are forbidden" — so every
--    run of this cron silently failed with an exception.
--    FIX: Replace with a call to a new SECURITY DEFINER function
--    expire_stale_pending_payments() that sets the flag correctly.
--
--  BUG 3 (retry-matching still has the 6-field schedule from 10_cron.sql)
--    v8_6_bugfixes.sql unschedules and re-schedules with valid syntax,
--    but only if that migration has been applied. This file re-applies
--    it defensively to guarantee the correct schedule regardless of
--    migration order.
-- ═══════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────
-- SECTION 1 — Fix expire-offers cron (BUG 1)
-- ─────────────────────────────────────────────────────────────────

DO $$
BEGIN
  PERFORM cron.unschedule('expire-offers');
EXCEPTION WHEN OTHERS THEN
  NULL; -- job didn't exist; harmless
END;
$$;

-- Supabase pg_cron minimum resolution is 1 minute (5-field syntax only).
-- expire_offers() marks each offer expired and immediately calls
-- match_fixers() so re-matching is as fast as possible.
SELECT cron.schedule(
  'expire-offers',
  '* * * * *',   -- every minute; valid 5-field pg_cron syntax
  $$ SELECT expire_offers(); $$
);


-- ─────────────────────────────────────────────────────────────────
-- SECTION 2 — Fix expire-pending-payments cron (BUG 2)
-- ─────────────────────────────────────────────────────────────────

-- Helper function that sets the status-change flag before updating.
CREATE OR REPLACE FUNCTION expire_stale_pending_payments()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  UPDATE bookings
  SET
    status     = 'EXPIRED',
    updated_at = now(),
    version    = version + 1
  WHERE status    = 'PENDING_PAYMENT'
    AND created_at < now() - interval '30 minutes';

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Audit trail for each expired booking
  INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata)
  SELECT
    id,
    'payment_timeout',
    'PENDING_PAYMENT',
    'EXPIRED',
    jsonb_build_object('reason', 'payment_not_received_within_30m')
  FROM bookings
  WHERE status     = 'EXPIRED'
    AND updated_at >= now() - interval '5 seconds'
    AND NOT EXISTS (
      SELECT 1 FROM booking_events be
      WHERE  be.booking_id  = bookings.id
        AND  be.event_type  = 'payment_timeout'
    );

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION expire_stale_pending_payments() TO service_role;

-- Re-schedule the cron to use the safe helper
DO $$
BEGIN
  PERFORM cron.unschedule('expire-pending-payments');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$$;

SELECT cron.schedule(
  'expire-pending-payments',
  '*/5 * * * *',
  $$ SELECT expire_stale_pending_payments(); $$
);


-- ─────────────────────────────────────────────────────────────────
-- SECTION 3 — Re-apply retry-matching fix defensively (BUG 3)
-- ─────────────────────────────────────────────────────────────────

DO $$
BEGIN
  PERFORM cron.unschedule('retry-matching');
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$$;

SELECT cron.schedule(
  'retry-matching',
  '*/2 * * * *',    -- every 2 minutes; valid 5-field pg_cron syntax
  $$
    SELECT match_fixers(id)
    FROM   bookings
    WHERE  status         = 'SEARCHING'
      AND  payment_status = 'paid'
      AND  (
        current_offer_id IS NULL
        OR offer_expires_at < now()
      )
      AND  (
        booking_mode = 'asap'
        OR (booking_mode = 'scheduled' AND scheduled_for <= now() + interval '2 hours')
      );
  $$
);


-- ─────────────────────────────────────────────────────────────────
-- SECTION 4 — Migration record
-- ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS schema_migrations (
  version     TEXT        PRIMARY KEY,
  applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO schema_migrations (version) VALUES ('v8.8')
ON CONFLICT (version) DO NOTHING;
