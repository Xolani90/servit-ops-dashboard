-- ═══════════════════════════════════════════════════════════════
-- v8.9.3 — Make admin_overrides.booking_id nullable
-- Needed so set_fixer_status (and other non-booking admin actions)
-- can write proper audit rows without a booking context.
-- Safe to run on existing data: all current rows already have a
-- non-null booking_id so the constraint drop has zero impact on them.
-- ═══════════════════════════════════════════════════════════════

-- 1. Drop the NOT NULL constraint (keep the FK for rows that do
--    reference a booking — it just becomes optional).
ALTER TABLE admin_overrides
  ALTER COLUMN booking_id DROP NOT NULL;

-- 2. Record migration
INSERT INTO schema_migrations (version)
VALUES ('v8.9.3')
ON CONFLICT DO NOTHING;
