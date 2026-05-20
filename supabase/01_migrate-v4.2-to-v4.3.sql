-- ═══════════════════════════════════════════════════════════════
-- SERVIT v4.3 — Migration (fixed for actual schema)
-- Uses: fixers (not pro_profiles), bookings.fixer_id/customer_id
-- Safe to run multiple times (uses IF NOT EXISTS / DO blocks).
-- ═══════════════════════════════════════════════════════════════

-- ── 1. ADD MISSING COLUMNS TO fixers ─────────────────────────

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='fixers' AND column_name='latitude') THEN
    ALTER TABLE fixers ADD COLUMN latitude  DOUBLE PRECISION;
    ALTER TABLE fixers ADD COLUMN longitude DOUBLE PRECISION;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='fixers' AND column_name='last_seen_at') THEN
    ALTER TABLE fixers ADD COLUMN last_seen_at TIMESTAMPTZ DEFAULT now();
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='fixers' AND column_name='acceptance_rate') THEN
    ALTER TABLE fixers ADD COLUMN acceptance_rate NUMERIC(5,2) DEFAULT 100.0;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='fixers' AND column_name='jobs_completed') THEN
    ALTER TABLE fixers ADD COLUMN jobs_completed INTEGER DEFAULT 0;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='fixers' AND column_name='rating') THEN
    ALTER TABLE fixers ADD COLUMN rating       NUMERIC(3,2) DEFAULT 0;
    ALTER TABLE fixers ADD COLUMN review_count INTEGER DEFAULT 0;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='fixers' AND column_name='available') THEN
    ALTER TABLE fixers ADD COLUMN available BOOLEAN DEFAULT true;
  END IF;
END $$;

-- ── 2. REVIEWS TABLE ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS reviews (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id   UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  reviewer_id  UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  reviewee_id  UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  fixer_id     UUID NOT NULL REFERENCES fixers(id) ON DELETE CASCADE,
  rating       INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment      TEXT,
  created_at   TIMESTAMPTZ DEFAULT now(),
  UNIQUE(booking_id, reviewer_id)
);

CREATE INDEX IF NOT EXISTS idx_reviews_fixer_id    ON reviews(fixer_id);
CREATE INDEX IF NOT EXISTS idx_reviews_reviewer_id ON reviews(reviewer_id);
CREATE INDEX IF NOT EXISTS idx_reviews_booking_id  ON reviews(booking_id);

ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reviews_select_public   ON reviews;
DROP POLICY IF EXISTS reviews_insert_customer ON reviews;

CREATE POLICY reviews_select_public ON reviews FOR SELECT USING (true);
CREATE POLICY reviews_insert_customer ON reviews FOR INSERT WITH CHECK (auth.uid() = reviewer_id);

-- ── 3. PAYOUTS TABLE ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS payouts (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id      UUID NOT NULL REFERENCES bookings(id) ON DELETE RESTRICT,
  fixer_id        UUID NOT NULL REFERENCES fixers(id) ON DELETE RESTRICT,
  gross_amount    NUMERIC(10,2) NOT NULL,
  commission_pct  NUMERIC(5,2)  NOT NULL DEFAULT 15.0,
  commission_amt  NUMERIC(10,2) NOT NULL,
  net_amount      NUMERIC(10,2) NOT NULL,
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','held','released','paid','cancelled')),
  hold_until      TIMESTAMPTZ,
  released_at     TIMESTAMPTZ,
  paid_at         TIMESTAMPTZ,
  payment_method  TEXT DEFAULT 'eft',
  notes           TEXT,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE(booking_id)
);

CREATE INDEX IF NOT EXISTS idx_payouts_fixer_id   ON payouts(fixer_id);
CREATE INDEX IF NOT EXISTS idx_payouts_status     ON payouts(status);
CREATE INDEX IF NOT EXISTS idx_payouts_hold_until ON payouts(hold_until) WHERE status = 'held';

ALTER TABLE payouts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS payouts_select_fixer ON payouts;
DROP POLICY IF EXISTS payouts_select_pro   ON payouts;

CREATE POLICY payouts_select_fixer ON payouts
  FOR SELECT USING (
    auth.uid() = (SELECT user_id FROM fixers WHERE id = fixer_id)
  );

-- ── 4. FIXER CATEGORIES (many-to-many) ───────────────────────
CREATE TABLE IF NOT EXISTS fixer_categories (
  id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  fixer_id  UUID NOT NULL REFERENCES fixers(id) ON DELETE CASCADE,
  category  TEXT NOT NULL,
  UNIQUE(fixer_id, category)
);

CREATE INDEX IF NOT EXISTS idx_fixer_categories_fixer_id ON fixer_categories(fixer_id);
CREATE INDEX IF NOT EXISTS idx_fixer_categories_category ON fixer_categories(category);

ALTER TABLE fixer_categories ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fixer_categories_select     ON fixer_categories;
DROP POLICY IF EXISTS fixer_categories_insert_own ON fixer_categories;
DROP POLICY IF EXISTS fixer_categories_delete_own ON fixer_categories;

CREATE POLICY fixer_categories_select ON fixer_categories FOR SELECT USING (true);
CREATE POLICY fixer_categories_insert_own ON fixer_categories
  FOR INSERT WITH CHECK (auth.uid() = (SELECT user_id FROM fixers WHERE id = fixer_id));
CREATE POLICY fixer_categories_delete_own ON fixer_categories
  FOR DELETE USING (auth.uid() = (SELECT user_id FROM fixers WHERE id = fixer_id));

-- ── 5. SCHEMA ADDITIONS TO EXISTING TABLES ───────────────────

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='bookings' AND column_name='category') THEN
    ALTER TABLE bookings ADD COLUMN category TEXT;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS disputes (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id   UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  raised_by    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  reason       TEXT NOT NULL,
  evidence_url TEXT,
  resolution   TEXT,
  resolved_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ DEFAULT now(),
  resolved_by  UUID REFERENCES auth.users(id),
  outcome      TEXT CHECK (outcome IN ('refund_customer','pay_fixer','split','dismissed')),
  admin_notes  TEXT,
  updated_at   TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_disputes_booking_id  ON disputes(booking_id);
CREATE INDEX IF NOT EXISTS idx_disputes_raised_by   ON disputes(raised_by);
CREATE INDEX IF NOT EXISTS idx_disputes_resolved_at ON disputes(resolved_at) WHERE resolved_at IS NULL;

ALTER TABLE disputes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS disputes_select_parties ON disputes;
DROP POLICY IF EXISTS disputes_insert_parties ON disputes;

CREATE POLICY disputes_select_parties ON disputes
  FOR SELECT USING (
    auth.uid() = raised_by
    OR auth.uid() = (SELECT customer_id FROM bookings WHERE id = booking_id)
    OR auth.uid() = (SELECT user_id FROM fixers WHERE id =
        (SELECT fixer_id FROM bookings WHERE id = booking_id))
    OR auth.uid() = (SELECT id FROM profiles WHERE id = auth.uid() AND user_role = 'admin')
  );

CREATE POLICY disputes_insert_parties ON disputes
  FOR INSERT WITH CHECK (auth.uid() = raised_by);

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='disputes' AND column_name='resolved_by') THEN
    ALTER TABLE disputes ADD COLUMN resolved_by UUID REFERENCES auth.users(id);
    ALTER TABLE disputes ADD COLUMN outcome TEXT CHECK (outcome IN ('refund_customer','pay_fixer','split','dismissed'));
    ALTER TABLE disputes ADD COLUMN admin_notes TEXT;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='disputes' AND column_name='updated_at') THEN
    ALTER TABLE disputes ADD COLUMN updated_at TIMESTAMPTZ DEFAULT now();
  END IF;
END $$;

-- ── 6. REALTIME ───────────────────────────────────────────────
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE reviews;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE payouts;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ── 7. BACKFILL fixer_categories from fixers.category ────────
INSERT INTO fixer_categories (fixer_id, category)
SELECT id, category FROM fixers
WHERE category IS NOT NULL AND category != ''
ON CONFLICT (fixer_id, category) DO NOTHING;

SELECT 'Migration v4.3 schema complete. Now run the .sql function files.' AS status;
