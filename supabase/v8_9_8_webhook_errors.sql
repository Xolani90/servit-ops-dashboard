-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8.9.8 — Webhook Errors Table
--
-- Creates webhook_errors table for logging webhook processing errors
-- from yoco-webhook.js and other webhook handlers.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Create webhook_errors table ───────────────────────────────
CREATE TABLE IF NOT EXISTS webhook_errors (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id UUID REFERENCES bookings(id),
  error_type TEXT NOT NULL,
  error_message TEXT,
  raw_payload JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ── 2. Add index for booking_id lookups ─────────────────────────────
CREATE INDEX IF NOT EXISTS idx_webhook_errors_booking_id ON webhook_errors(booking_id);

-- ── 3. Enable RLS ─────────────────────────────────────────────────
ALTER TABLE webhook_errors ENABLE ROW LEVEL SECURITY;

-- ── 4. RLS Policies ────────────────────────────────────────────────
-- Admins can read all rows
CREATE POLICY "Admins can read webhook_errors"
  ON webhook_errors FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE id = auth.uid()
      AND user_role = 'admin'
    )
  );

-- No other access (default deny)

-- ── 5. Migration tracking ───────────────────────────────────────────
INSERT INTO schema_migrations (version) VALUES ('v8.9.8') ON CONFLICT DO NOTHING;
