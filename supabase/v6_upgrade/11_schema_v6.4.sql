-- ═══════════════════════════════════════════════════════════════
-- SERVIT v6.4 — Schema additions
-- Favourite fixers, rebook support, premium priority queue
-- ═══════════════════════════════════════════════════════════════

-- Favourite fixers
CREATE TABLE IF NOT EXISTS favourite_fixers (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  customer_id  UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  fixer_id     UUID NOT NULL REFERENCES fixers(id) ON DELETE CASCADE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(customer_id, fixer_id)
);

CREATE INDEX IF NOT EXISTS idx_fav_fixers_customer ON favourite_fixers(customer_id);

-- RLS
ALTER TABLE favourite_fixers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fav_fixers_own ON favourite_fixers;
CREATE POLICY fav_fixers_own ON favourite_fixers
  FOR ALL USING (customer_id = auth.uid());

-- Premium queue tracking — how many seconds faster premium jobs dispatch
ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS premium_queue_position INTEGER,
  ADD COLUMN IF NOT EXISTS time_to_first_accept    INTEGER;  -- seconds, recorded on accept

-- Record when first accepted (for premium SLA tracking)
INSERT INTO schema_migrations (version) VALUES ('v6.4') ON CONFLICT DO NOTHING;
