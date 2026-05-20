-- ═══════════════════════════════════════════════════════════════
-- SERVIT v6.0 — Schema Upgrade
-- Adds: service_tier, fixer_status, dispatch support,
--       trust layer, adaptive matching columns
-- Safe to run on existing v5.2 database (all IF NOT EXISTS)
-- ═══════════════════════════════════════════════════════════════

-- ── New ENUMs ─────────────────────────────────────────────────
DO $$ BEGIN
  CREATE TYPE service_tier_enum AS ENUM ('basic', 'standard', 'premium');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE fixer_status_enum AS ENUM ('online', 'offline', 'busy');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE dispatch_status_enum AS ENUM ('pending', 'notified', 'accepted', 'timed_out', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── Upgrade bookings table ────────────────────────────────────
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS service_tier    service_tier_enum NOT NULL DEFAULT 'standard',
  ADD COLUMN IF NOT EXISTS dispatch_mode   TEXT              NOT NULL DEFAULT 'auto',  -- 'auto' | 'manual'
  ADD COLUMN IF NOT EXISTS dispatch_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS dispatch_expiry TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS fallback_at     TIMESTAMPTZ,      -- when dispatch fell back to offer mode
  ADD COLUMN IF NOT EXISTS admin_note      TEXT;             -- for manual override notes

-- ── Upgrade fixers table (trust layer) ───────────────────────
ALTER TABLE fixers
  ADD COLUMN IF NOT EXISTS fixer_status       fixer_status_enum NOT NULL DEFAULT 'offline',
  ADD COLUMN IF NOT EXISTS is_verified        BOOLEAN           NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS response_time_avg  INTEGER,          -- seconds, rolling average
  ADD COLUMN IF NOT EXISTS jobs_completed     INTEGER           NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_active_at     TIMESTAMPTZ;

-- Migrate existing available column → fixer_status
UPDATE fixers SET fixer_status = 'online'  WHERE available = true  AND fixer_status = 'offline';
UPDATE fixers SET fixer_status = 'offline' WHERE available = false AND fixer_status = 'offline';

-- ── Dispatch log table ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS dispatch_log (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id    UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  fixer_id      UUID NOT NULL REFERENCES fixers(id)   ON DELETE CASCADE,
  status        dispatch_status_enum NOT NULL DEFAULT 'pending',
  notified_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  responded_at  TIMESTAMPTZ,
  score         NUMERIC(6,2),     -- matching score at dispatch time
  tier          service_tier_enum,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dispatch_log_booking ON dispatch_log(booking_id);
CREATE INDEX IF NOT EXISTS idx_dispatch_log_fixer   ON dispatch_log(fixer_id);

-- ── Admin overrides table ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_overrides (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id    UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  admin_id      UUID NOT NULL REFERENCES auth.users(id),
  action        TEXT NOT NULL,   -- 'assign_fixer' | 'force_status' | 'resolve_stuck'
  payload       JSONB,
  note          TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Indexes ───────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_bookings_tier    ON bookings(service_tier);
CREATE INDEX IF NOT EXISTS idx_fixers_status    ON fixers(fixer_status);
CREATE INDEX IF NOT EXISTS idx_fixers_verified  ON fixers(is_verified);

-- ── Record migration ──────────────────────────────────────────
INSERT INTO schema_migrations (version) VALUES ('v6.0') ON CONFLICT DO NOTHING;
