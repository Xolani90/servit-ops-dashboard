-- ═══════════════════════════════════════════════════════════════
-- SERVIT v4.3 — Additional RLS Policies (fixed for actual schema)
-- Run AFTER 01_migrate-v4.2-to-v4.3.sql
-- ═══════════════════════════════════════════════════════════════

-- ── REVIEWS ──────────────────────────────────────────────────
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS reviews_select_public   ON reviews;
DROP POLICY IF EXISTS reviews_insert_customer ON reviews;

CREATE POLICY reviews_select_public ON reviews FOR SELECT USING (true);
CREATE POLICY reviews_insert_customer ON reviews FOR INSERT WITH CHECK (auth.uid() = reviewer_id);

-- ── PAYOUTS ──────────────────────────────────────────────────
ALTER TABLE payouts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS payouts_select_fixer ON payouts;
DROP POLICY IF EXISTS payouts_select_pro   ON payouts;

CREATE POLICY payouts_select_fixer ON payouts
  FOR SELECT USING (
    auth.uid() = (SELECT user_id FROM fixers WHERE id = fixer_id)
  );

-- ── FIXER CATEGORIES ─────────────────────────────────────────
ALTER TABLE fixer_categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fixer_categories_select     ON fixer_categories;
DROP POLICY IF EXISTS fixer_categories_insert_own ON fixer_categories;
DROP POLICY IF EXISTS fixer_categories_delete_own ON fixer_categories;
-- Also drop old pro_categories names if they exist
DROP POLICY IF EXISTS pro_categories_select     ON fixer_categories;
DROP POLICY IF EXISTS pro_categories_insert_own ON fixer_categories;
DROP POLICY IF EXISTS pro_categories_delete_own ON fixer_categories;

CREATE POLICY fixer_categories_select ON fixer_categories FOR SELECT USING (true);

CREATE POLICY fixer_categories_insert_own ON fixer_categories
  FOR INSERT WITH CHECK (
    auth.uid() = (SELECT user_id FROM fixers WHERE id = fixer_id)
  );

CREATE POLICY fixer_categories_delete_own ON fixer_categories
  FOR DELETE USING (
    auth.uid() = (SELECT user_id FROM fixers WHERE id = fixer_id)
  );

-- ── DISPUTES — admin update policy ───────────────────────────
DROP POLICY IF EXISTS disputes_update_admin ON disputes;

CREATE POLICY disputes_update_admin ON disputes
  FOR UPDATE USING (
    auth.uid() = (SELECT id FROM profiles WHERE id = auth.uid() AND user_role = 'admin')
  );
