-- ═══════════════════════════════════════════════════════════════
-- SERVIT v5.2 — pg_cron Jobs
-- Changes from v5.1:
--   FIX 5: Added escalate-disputes hourly cron.
--           Disputes that have been open > 48h now generate an
--           admin notification. Previously disputes had no SLA
--           timer and could sit unresolved indefinitely.
-- ═══════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ── 1. Expire offers that have passed their 45s window ────────
SELECT cron.schedule(
  'expire-offers',
  '* * * * *',  -- FIX (v8.8): valid 5-field syntax; '*/10 * * * * *' was invalid on Supabase
  $$ SELECT expire_offers(); $$
);

-- ── 2. Retry matching for stuck SEARCHING bookings ────────────
-- Radius expands automatically with each retry pass:
--   Pass 0 (first attempt): 25 km (default)
--   Pass 1 (30s later):     40 km
--   Pass 2 (60s later):     55 km
--   Pass 3+ (90s+):         70 km (capped)
-- This mirrors Uber's radius-expansion strategy — start tight for
-- quality, widen progressively to avoid leaving customers unmatched.
--
-- GRACE PERIOD: bookings are excluded for the first 30 seconds after
-- creation (= one full cron cycle) so the initial match attempt fired
-- by yoco-webhook / create-booking has time to complete and log its
-- booking_event before the cron picks up the same booking and fires
-- a redundant second attempt. Without this guard, a booking created
-- at t=0 would be matched at t≈1s (webhook), then AGAIN at t=29s
-- (cron), before the first offer had any time to expire.
SELECT cron.unschedule('retry-matching');   -- drop old direct match_fixers job
-- Now using request_matching pattern - worker processes requests
-- This cron is now redundant since the worker runs every 5 seconds
-- Kept for reference but disabled
-- SELECT cron.schedule(
--   'retry-matching-db',
--   '*/30 * * * * *',
--   $$
--     INSERT INTO matching_requests (booking_id, requested_by, priority, radius_km, batch_size, metadata)
--     SELECT
--       b.id,
--       'db-cron' as requested_by,
--       4 as priority,
--       LEAST(70.0, 25.0 + (
--         SELECT COUNT(*)::DOUBLE PRECISION * 15.0
--         FROM   booking_events be
--         WHERE  be.booking_id  = b.id
--           AND  be.event_type IN ('match_attempt', 'manual_retry_search')
--       )) as radius_km,
--       3 as batch_size,
--       jsonb_build_object('source', 'db-cron') as metadata
--     FROM   bookings b
--     WHERE  b.status         = 'SEARCHING'
--       AND  b.payment_status = 'paid'
--       AND  (b.current_offer_id IS NULL OR b.offer_expires_at < now())
--       AND  b.created_at     < now() - interval '30 seconds'
--       AND  (
--         b.booking_mode = 'asap'
--         OR (b.booking_mode = 'scheduled' AND b.scheduled_for <= now() + interval '2 hours')
--       )
--       AND NOT EXISTS (
--         SELECT 1 FROM matching_requests mr
--         WHERE mr.booking_id = b.id AND mr.processed = false
--       )
--     ON CONFLICT (booking_id, processed) WHERE processed = false DO NOTHING;
--   $$
-- );

-- ── 3. Release payouts after 24h hold ────────────────────────
SELECT cron.schedule(
  'release-payouts',
  '*/30 * * * *',
  $$ SELECT release_due_payouts(); $$
);

-- ── 4. Expire PENDING_PAYMENT bookings after 30 minutes ──────
SELECT cron.schedule(
  'expire-pending-payments',
  '*/5 * * * *',
  $$
    UPDATE bookings
    SET    status     = 'EXPIRED',
           updated_at = now()
    WHERE  status    = 'PENDING_PAYMENT'
      AND  created_at < now() - interval '30 minutes';
  $$
);

-- ── 5. Activate scheduled bookings within 2h window ──────────
SELECT cron.schedule(
  'activate-scheduled-bookings',
  '*/5 * * * *',
  $$ SELECT activate_scheduled_bookings(); $$
);

-- ── 6. FIX 5: Dispute escalation SLA ─────────────────────────
-- Runs every hour. Inserts an admin notification for every dispute
-- open more than 48h. Deduplicates: max one alert per dispute per 24h.
SELECT cron.schedule(
  'escalate-disputes',
  '0 * * * *',
  $$
    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT
      p.id,
      '🚨 Dispute overdue (48h)',
      'Booking ' || b.id::TEXT || ' has been DISPUTED for over 48 hours without resolution.',
      'dispute_escalation',
      b.id
    FROM  bookings b
    CROSS JOIN profiles p
    WHERE b.status     = 'DISPUTED'
      AND b.updated_at < now() - INTERVAL '48 hours'
      AND p.user_role  = 'admin'
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE  n.related_id  = b.id
          AND  n.type        = 'dispute_escalation'
          AND  n.created_at >= now() - INTERVAL '24 hours'
      );
  $$
);
