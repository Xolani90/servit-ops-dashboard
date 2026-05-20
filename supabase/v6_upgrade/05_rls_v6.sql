-- ═══════════════════════════════════════════════════════════════
-- SERVIT v6.0 — RLS Policies for new tables
-- ═══════════════════════════════════════════════════════════════

-- ── dispatch_log ──────────────────────────────────────────────
ALTER TABLE dispatch_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS dispatch_log_fixer_select ON dispatch_log;
CREATE POLICY dispatch_log_fixer_select ON dispatch_log
  FOR SELECT USING (
    fixer_id IN (SELECT id FROM fixers WHERE user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND user_role = 'admin')
  );

-- ── admin_overrides ───────────────────────────────────────────
ALTER TABLE admin_overrides ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS admin_overrides_admin_only ON admin_overrides;
CREATE POLICY admin_overrides_admin_only ON admin_overrides
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND user_role = 'admin')
  );

-- ── Fixers: allow authenticated to read online fixers ─────────
DROP POLICY IF EXISTS fixers_public_read ON fixers;
CREATE POLICY fixers_public_read ON fixers
  FOR SELECT USING (
    -- own record
    user_id = auth.uid()
    -- or admin
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND user_role = 'admin')
    -- or reading approved available fixers (for homepage list)
    OR (status = 'approved' AND fixer_status = 'online')
  );

DROP POLICY IF EXISTS fixers_update_own ON fixers;
CREATE POLICY fixers_update_own ON fixers
  FOR UPDATE USING (user_id = auth.uid());
