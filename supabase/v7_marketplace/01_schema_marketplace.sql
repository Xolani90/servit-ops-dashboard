-- ═══════════════════════════════════════════════════════════════
-- SERVIT v7.0 — MARKETPLACE SCHEMA ADDITIONS
-- Adds columns and tables required for all 7 marketplace features.
-- Safe to run on existing data — all ADD COLUMN IF NOT EXISTS.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. FIXERS: quality + performance columns ─────────────────────
ALTER TABLE fixers
  -- Quality gate columns
  ADD COLUMN IF NOT EXISTS is_flagged          BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS flag_reason         TEXT,
  ADD COLUMN IF NOT EXISTS flagged_at          TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS auto_suspended_at   TIMESTAMPTZ,

  -- Scoring columns (feed into build_dispatch_queue weighted score)
  ADD COLUMN IF NOT EXISTS completion_rate     NUMERIC(5,2) DEFAULT 100,   -- % of accepted jobs completed
  ADD COLUMN IF NOT EXISTS response_time_avg   INTEGER DEFAULT 120,         -- seconds median response
  ADD COLUMN IF NOT EXISTS fixer_status        TEXT DEFAULT 'online'
    CHECK (fixer_status IN ('online','offline','busy')),

  -- Lifecycle / engagement
  ADD COLUMN IF NOT EXISTS first_job_at        TIMESTAMPTZ,                 -- for win celebration
  ADD COLUMN IF NOT EXISTS last_online_at      TIMESTAMPTZ,                 -- for dormant detection
  ADD COLUMN IF NOT EXISTS total_earnings      NUMERIC(12,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_completed     INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS profile_complete    BOOLEAN GENERATED ALWAYS AS (
    full_name IS NOT NULL AND photo_url IS NOT NULL AND bio IS NOT NULL
  ) STORED;

-- ── 2. PROFILES: wallet credit + booking counters ────────────────
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS wallet_credit       NUMERIC(10,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS referral_code       TEXT UNIQUE,
  ADD COLUMN IF NOT EXISTS referred_by         TEXT,  -- referral code used at signup
  ADD COLUMN IF NOT EXISTS total_bookings      INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_booking_at     TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_category       TEXT,  -- most recently booked category
  ADD COLUMN IF NOT EXISTS last_fixer_id       UUID REFERENCES fixers(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS last_fixer_name     TEXT;

-- ── 3. REFERRALS table ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS referrals (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  referrer_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  referee_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  referral_code   TEXT NOT NULL,
  credit_issued   BOOLEAN NOT NULL DEFAULT false,
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE (referee_id)  -- one referral per new user
);

-- ── 4. WALLET TRANSACTIONS log ────────────────────────────────────
CREATE TABLE IF NOT EXISTS wallet_transactions (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  amount          NUMERIC(10,2) NOT NULL,  -- positive = credit, negative = debit
  reason          TEXT NOT NULL,           -- 'referral_bonus', 'loyalty_reward', 'manual'
  related_id      UUID,                    -- booking_id or referral_id
  created_at      TIMESTAMPTZ DEFAULT now()
);

-- ── 5. SURGE SIGNAL view ─────────────────────────────────────────
-- Real-time demand/supply ratio per city+category.
-- A ratio > 2 means demand significantly outstrips supply.
CREATE OR REPLACE VIEW surge_signal AS
SELECT
  p.city,
  b.category,
  COUNT(DISTINCT b.id)                                        AS searching_bookings,
  COUNT(DISTINCT f.id)                                        AS available_fixers,
  CASE
    WHEN COUNT(DISTINCT f.id) = 0 THEN 10           -- no fixers → max surge
    ELSE ROUND(COUNT(DISTINCT b.id)::NUMERIC / COUNT(DISTINCT f.id), 2)
  END                                                         AS demand_ratio,
  CASE
    WHEN COUNT(DISTINCT f.id) = 0 THEN true
    WHEN COUNT(DISTINCT b.id)::NUMERIC / NULLIF(COUNT(DISTINCT f.id),0) >= 2 THEN true
    ELSE false
  END                                                         AS is_surge
FROM bookings b
JOIN profiles p ON p.id = b.customer_id
LEFT JOIN fixers f ON f.city = p.city
  AND f.fixer_status = 'online'
  AND f.last_seen_at >= now() - interval '5 minutes'
  AND f.status = 'approved'
  AND (
    b.category IS NULL
    OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
    OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id = f.id AND fc.category = b.category)
  )
WHERE b.status IN ('SEARCHING', 'OFFERED')
  AND b.created_at >= now() - interval '1 hour'
GROUP BY p.city, b.category;

GRANT SELECT ON surge_signal TO anon, authenticated, service_role;

-- ── 6. FIXER DRIP MESSAGES table (zero-infra version) ────────────
-- Instead of a real drip tool, we queue nudges here and Netlify
-- picks them up on a scheduled function.
CREATE TABLE IF NOT EXISTS fixer_nudges (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  fixer_id        UUID NOT NULL REFERENCES fixers(id) ON DELETE CASCADE,
  nudge_type      TEXT NOT NULL,  -- 'day1_tip','day3_photo','dormant','first_job_win'
  scheduled_for   TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at         TIMESTAMPTZ,
  channel         TEXT DEFAULT 'push',  -- 'push' | 'whatsapp'
  payload         JSONB,
  UNIQUE (fixer_id, nudge_type)   -- only one pending nudge per type per fixer
);

-- ── 7. Indexes ────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_fixers_is_flagged   ON fixers(is_flagged) WHERE is_flagged = true;
CREATE INDEX IF NOT EXISTS idx_fixers_last_online  ON fixers(last_online_at);
CREATE INDEX IF NOT EXISTS idx_fixers_fixer_status ON fixers(fixer_status, last_seen_at);
CREATE INDEX IF NOT EXISTS idx_referrals_code      ON referrals(referral_code);
CREATE INDEX IF NOT EXISTS idx_wallet_txn_user     ON wallet_transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_fixer_nudges_sched  ON fixer_nudges(scheduled_for) WHERE sent_at IS NULL;

-- ── 8. Referral code auto-generate on profile insert ─────────────
CREATE OR REPLACE FUNCTION generate_referral_code()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.referral_code IS NULL THEN
    NEW.referral_code := 'SERVIT-' || UPPER(SUBSTRING(REPLACE(NEW.id::TEXT, '-', '') FROM 1 FOR 6));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_generate_referral_code ON profiles;
CREATE TRIGGER trg_generate_referral_code
  BEFORE INSERT ON profiles
  FOR EACH ROW EXECUTE FUNCTION generate_referral_code();

-- Backfill existing profiles without referral codes
UPDATE profiles
SET referral_code = 'SERVIT-' || UPPER(SUBSTRING(REPLACE(id::TEXT, '-', '') FROM 1 FOR 6))
WHERE referral_code IS NULL;

-- ── BUG-H2 FIX: Normalise fixer_status DEFAULT (idempotent) ────────
-- v6 defines fixer_status as an ENUM defaulting to 'offline'.
-- v7 attempted to re-add it as TEXT defaulting to 'online' — the IF NOT EXISTS
-- means the column stays as the v6 ENUM type, but the conflicting DEFAULT 'online'
-- means fresh v7-only installs would surface new fixers as online by default.
-- This block ensures the DEFAULT is always 'offline' regardless of migration path.
DO $$
BEGIN
  ALTER TABLE fixers ALTER COLUMN fixer_status SET DEFAULT 'offline';
EXCEPTION WHEN others THEN NULL;
END;
$$;
