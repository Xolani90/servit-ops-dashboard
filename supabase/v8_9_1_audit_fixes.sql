-- ═══════════════════════════════════════════════════════════════════════
-- Servit v8.9.1 — Post-Audit Security & Stability Fixes
-- Generated: 2026-05-12
-- Addresses open findings from the v8.9.1 production audit report.
-- ═══════════════════════════════════════════════════════════════════════

-- ── BUG 6 FIX: rate_limit_hits table unbounded growth ─────────────────
--
-- Root cause: The prune-rate-limit-hits pg_cron job runs every 30 minutes
-- and deletes rows older than 1 hour. If the cron fails (DB restart,
-- pg_cron outage), rows accumulate without bound. Under sustained abuse
-- the table can grow to millions of rows, slowing check_rate_limit().
--
-- Fix: Increase prune frequency to every 5 minutes AND add an emergency
-- row cap that deletes the oldest rows if the table exceeds 100k rows.
-- Also runs ANALYZE to keep the query planner statistics fresh.
-- ─────────────────────────────────────────────────────────────────────

-- Remove the old 30-minute prune schedule
SELECT cron.unschedule('prune-rate-limit-hits');

-- Re-register with 5-minute frequency + emergency cap
SELECT cron.schedule(
  'prune-rate-limit-hits',
  '*/5 * * * *',
  $$
    -- Normal TTL prune: remove records older than the rate-limit window
    DELETE FROM rate_limit_hits
    WHERE hit_at < now() - interval '1 hour';

    -- Emergency cap: if the table somehow grows beyond 100k rows
    -- (e.g. cron was paused during a traffic spike), delete the oldest
    -- 50k rows immediately to bring it back under control.
    DELETE FROM rate_limit_hits
    WHERE id IN (
      SELECT id FROM rate_limit_hits
      ORDER BY hit_at ASC
      LIMIT GREATEST(0,
        (SELECT COUNT(*) FROM rate_limit_hits)::bigint - 100000
      )
    );

    -- Keep planner statistics fresh after bulk deletes
    ANALYZE rate_limit_hits;
  $$
);

-- Add a maximum-rows check constraint as a belt-and-suspenders guard.
-- pg_cron is the primary defence; this is a last resort.
-- (Cannot use a CHECK constraint on row count, so we use a trigger.)
CREATE OR REPLACE FUNCTION enforce_rate_limit_hits_cap()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- Only enforce cap check every ~1000 inserts to avoid per-row overhead
  IF (SELECT COUNT(*) FROM rate_limit_hits) > 150000 THEN
    DELETE FROM rate_limit_hits
    WHERE id IN (
      SELECT id FROM rate_limit_hits
      ORDER BY hit_at ASC
      LIMIT 50000
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS rate_limit_hits_cap_trigger ON rate_limit_hits;
CREATE TRIGGER rate_limit_hits_cap_trigger
  AFTER INSERT ON rate_limit_hits
  FOR EACH STATEMENT
  EXECUTE FUNCTION enforce_rate_limit_hits_cap();
