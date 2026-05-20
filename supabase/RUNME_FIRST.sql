-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8.4 — Run this FIRST in Supabase SQL Editor
-- Fixes all 500/403 errors in the frontend
-- ═══════════════════════════════════════════════════════════════

-- BUG 13 FIX: uuid-ossp was missing — uuid_generate_v4() calls in
-- schema.sql throw "function uuid_generate_v4() does not exist"
-- if only pgcrypto is enabled. Both extensions must be enabled.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Step 2: Add missing column (v5.2 compat)
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS category TEXT;

-- Step 3: Migration record
CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ DEFAULT now()
);
INSERT INTO schema_migrations VALUES ('v5.1') ON CONFLICT DO NOTHING;
INSERT INTO schema_migrations VALUES ('v5.2') ON CONFLICT DO NOTHING;
