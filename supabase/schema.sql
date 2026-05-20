-- ═══════════════════════════════════════════════════════════════
-- SERVIT v5.2 — Complete Production Schema
-- Changes from v5.1:
--   • bookings.category column now declared in base schema
--   • booking_events.old_status / new_status remain booking_status_enum
--     (mark_payment_refunded fixed separately to not cast payment states)
--   • schema_migrations table added
-- Run this in Supabase SQL Editor on a fresh project.
-- ═══════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─── Migration guard table ────────────────────────────────────
CREATE TABLE IF NOT EXISTS schema_migrations (
  version    TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ DEFAULT now()
);
INSERT INTO schema_migrations (version) VALUES ('v5.2') ON CONFLICT DO NOTHING;

-- ═══════════════════════════════════════════════════════════════
-- ENUM TYPES
-- ═══════════════════════════════════════════════════════════════

DO $$ BEGIN
  CREATE TYPE booking_status_enum AS ENUM (
    'CREATED',
    'PENDING_PAYMENT',
    'SEARCHING',
    'OFFERED',
    'CONFIRMED',
    'EN_ROUTE',
    'ARRIVED',
    'IN_PROGRESS',
    'PENDING_COMPLETION',
    'COMPLETED',
    'CANCELLED',
    'DISPUTED',
    'EXPIRED'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE payment_status_enum AS ENUM (
    'pending',
    'paid',
    'failed',
    'refunded'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE offer_status_enum AS ENUM (
    'pending',
    'accepted',
    'declined',
    'expired'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE TYPE booking_mode_enum AS ENUM (
    'asap',
    'scheduled'
  );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ═══════════════════════════════════════════════════════════════
-- PROFILES (extends auth.users)
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS profiles (
  id            UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name     TEXT,
  email         TEXT,
  phone         TEXT,
  city          TEXT,
  avatar_url    TEXT,
  user_role     TEXT DEFAULT 'customer' CHECK (user_role IN ('customer', 'fixer', 'admin')),
  referral_source TEXT,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

-- ═══════════════════════════════════════════════════════════════
-- FIXER PROFILES
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS fixers (
  id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id            UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  full_name          TEXT,
  business_name      TEXT,
  city               TEXT,
  phone              TEXT,
  bio                TEXT,
  category           TEXT,
  service_title      TEXT,
  service_description TEXT,
  service_mode       TEXT DEFAULT 'mobile',
  price              NUMERIC(10,2),
  price_type         TEXT DEFAULT 'hour',
  available          BOOLEAN DEFAULT false,
  status             TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'suspended')),
  rating             NUMERIC(3,2) DEFAULT 0,
  review_count       INTEGER DEFAULT 0,
  jobs_completed     INTEGER DEFAULT 0,
  acceptance_rate    INTEGER DEFAULT 100,
  -- Documents
  id_document_path   TEXT,
  police_clearance_path TEXT,
  police_cleared     BOOLEAN DEFAULT false,
  photo_url          TEXT,
  -- Bank details
  bank_name          TEXT,
  account_holder     TEXT,
  account_number_encrypted TEXT,
  branch_code        TEXT,
  -- Geolocation (updated by heartbeat every 60s)
  latitude           DOUBLE PRECISION,
  longitude          DOUBLE PRECISION,
  -- Heartbeat — match_fixers excludes fixers not seen in 3min
  last_seen_at       TIMESTAMPTZ,
  created_at         TIMESTAMPTZ DEFAULT now(),
  updated_at         TIMESTAMPTZ DEFAULT now()
);

-- ═══════════════════════════════════════════════════════════════
-- BOOKINGS (CORE TABLE)
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS bookings (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  customer_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  fixer_id              UUID REFERENCES fixers(id) ON DELETE SET NULL,
  status                booking_status_enum NOT NULL DEFAULT 'CREATED',
  payment_status        payment_status_enum NOT NULL DEFAULT 'pending',
  booking_mode          booking_mode_enum NOT NULL DEFAULT 'asap',
  scheduled_for         TIMESTAMPTZ,
  description           TEXT,
  address               TEXT NOT NULL,
  customer_phone        TEXT,
  -- FIX v5.2: category column — required for match_fixers skill filtering
  category              TEXT,
  -- FIX v8.9.1: service_tier — must be in base schema to prevent silent patch failure
  -- on fresh installs.  v6_upgrade/01_schema_upgrade.sql adds this via ALTER TABLE IF NOT EXISTS
  -- but that path is not reached on a clean deploy that only applies schema.sql first.
  service_tier          TEXT NOT NULL DEFAULT 'standard' CHECK (service_tier IN ('basic', 'standard', 'premium')),
  -- Customer geolocation (captured at booking creation)
  customer_latitude     DOUBLE PRECISION,
  customer_longitude    DOUBLE PRECISION,
  -- Financials
  amount                NUMERIC(10,2) NOT NULL,
  commission            NUMERIC(10,2),
  platform_fee          NUMERIC(10,2),
  customer_total        NUMERIC(10,2),
  -- Payment
  payment_reference     TEXT,
  payment_verified_at   TIMESTAMPTZ,
  -- Offer tracking (when in OFFERED state)
  current_offer_id      UUID,
  offer_expires_at      TIMESTAMPTZ,
  -- Job progression timestamps
  created_at            TIMESTAMPTZ DEFAULT now(),
  payment_confirmed_at  TIMESTAMPTZ,
  matched_at            TIMESTAMPTZ,
  offered_at            TIMESTAMPTZ,
  confirmed_at          TIMESTAMPTZ,
  en_route_at           TIMESTAMPTZ,
  arrived_at            TIMESTAMPTZ,
  in_progress_at        TIMESTAMPTZ,
  pending_completion_at TIMESTAMPTZ,
  completed_at          TIMESTAMPTZ,
  cancelled_at          TIMESTAMPTZ,
  cancelled_reason      TEXT,
  updated_at            TIMESTAMPTZ DEFAULT now(),
  -- Optimistic lock version
  version               INTEGER DEFAULT 1
);

-- ═══════════════════════════════════════════════════════════════
-- PAYMENTS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS payments (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id            UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  amount                NUMERIC(10,2) NOT NULL,
  status                payment_status_enum NOT NULL DEFAULT 'pending',
  provider              TEXT NOT NULL DEFAULT 'yoco',
  provider_payment_id   TEXT,
  provider_checkout_id  TEXT,
  provider_checkout_url TEXT,
  metadata              JSONB,
  verified_at           TIMESTAMPTZ,
  created_at            TIMESTAMPTZ DEFAULT now(),
  updated_at            TIMESTAMPTZ DEFAULT now()
);

-- ═══════════════════════════════════════════════════════════════
-- OFFERS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS offers (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id   UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  fixer_id     UUID NOT NULL REFERENCES fixers(id) ON DELETE CASCADE,
  status       offer_status_enum NOT NULL DEFAULT 'pending',
  expires_at   TIMESTAMPTZ NOT NULL,
  created_at   TIMESTAMPTZ DEFAULT now(),
  responded_at TIMESTAMPTZ,
  UNIQUE(booking_id, fixer_id)
);

-- ═══════════════════════════════════════════════════════════════
-- BOOKING EVENTS (Audit Log)
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS booking_events (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id  UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  event_type  TEXT NOT NULL,
  -- NOTE: old_status / new_status are booking states only.
  -- Payment state changes go in metadata JSONB, not here.
  old_status  booking_status_enum,
  new_status  booking_status_enum,
  metadata    JSONB,
  created_by  UUID REFERENCES auth.users(id),
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- ═══════════════════════════════════════════════════════════════
-- DISPUTES
-- ═══════════════════════════════════════════════════════════════

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

-- ═══════════════════════════════════════════════════════════════
-- REVIEWS
-- ═══════════════════════════════════════════════════════════════

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

-- ═══════════════════════════════════════════════════════════════
-- PAYOUTS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS payouts (
  id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id     UUID NOT NULL REFERENCES bookings(id) ON DELETE RESTRICT,
  fixer_id       UUID NOT NULL REFERENCES fixers(id) ON DELETE RESTRICT,
  gross_amount   NUMERIC(10,2) NOT NULL,
  commission_pct NUMERIC(5,2)  NOT NULL DEFAULT 12.0,  -- FIX: was 15.0, now uses platform_commission_pct()
  commission_amt NUMERIC(10,2) NOT NULL,
  net_amount     NUMERIC(10,2) NOT NULL,
  status         TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','held','released','paid','cancelled')),
  hold_until     TIMESTAMPTZ,
  released_at    TIMESTAMPTZ,
  paid_at        TIMESTAMPTZ,
  payment_method TEXT DEFAULT 'eft',
  notes          TEXT,
  created_at     TIMESTAMPTZ DEFAULT now(),
  updated_at     TIMESTAMPTZ DEFAULT now(),
  UNIQUE(booking_id)
);

-- ═══════════════════════════════════════════════════════════════
-- FIXER CATEGORIES (many-to-many)
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS fixer_categories (
  id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  fixer_id  UUID NOT NULL REFERENCES fixers(id) ON DELETE CASCADE,
  category  TEXT NOT NULL,
  UNIQUE(fixer_id, category)
);

-- ═══════════════════════════════════════════════════════════════
-- NOTIFICATIONS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS notifications (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title      TEXT NOT NULL,
  body       TEXT,
  type       TEXT,
  related_id UUID,
  read       BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ═══════════════════════════════════════════════════════════════
-- MESSAGES
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS messages (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  sender_id   UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  receiver_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  booking_id  UUID REFERENCES bookings(id) ON DELETE SET NULL,
  content     TEXT NOT NULL,
  read        BOOLEAN DEFAULT false,
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- ═══════════════════════════════════════════════════════════════
-- PUSH SUBSCRIPTIONS
-- ═══════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS push_subscriptions (
  id         UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  endpoint   TEXT NOT NULL,
  keys       JSONB NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(user_id, endpoint)
);

-- ═══════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_bookings_customer_id    ON bookings(customer_id);
CREATE INDEX IF NOT EXISTS idx_bookings_fixer_id       ON bookings(fixer_id);
CREATE INDEX IF NOT EXISTS idx_bookings_status         ON bookings(status);
CREATE INDEX IF NOT EXISTS idx_bookings_payment_status ON bookings(payment_status);
CREATE INDEX IF NOT EXISTS idx_bookings_booking_mode   ON bookings(booking_mode);
CREATE INDEX IF NOT EXISTS idx_bookings_category       ON bookings(category);  -- FIX v5.2
CREATE INDEX IF NOT EXISTS idx_bookings_scheduled_for  ON bookings(scheduled_for) WHERE booking_mode = 'scheduled';
CREATE INDEX IF NOT EXISTS idx_bookings_offer_expires  ON bookings(offer_expires_at) WHERE status = 'OFFERED';
CREATE INDEX IF NOT EXISTS idx_bookings_coordinates    ON bookings(customer_latitude, customer_longitude)
  WHERE customer_latitude IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_offers_booking_id  ON offers(booking_id);
CREATE INDEX IF NOT EXISTS idx_offers_fixer_id    ON offers(fixer_id);
CREATE INDEX IF NOT EXISTS idx_offers_expires_at  ON offers(expires_at) WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_payments_booking_id          ON payments(booking_id);
CREATE INDEX IF NOT EXISTS idx_payments_provider_payment_id ON payments(provider_payment_id);

CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_read    ON notifications(user_id, read);

CREATE INDEX IF NOT EXISTS idx_messages_participants ON messages(sender_id, receiver_id);

CREATE INDEX IF NOT EXISTS idx_reviews_fixer_id    ON reviews(fixer_id);
CREATE INDEX IF NOT EXISTS idx_reviews_reviewer_id ON reviews(reviewer_id);
CREATE INDEX IF NOT EXISTS idx_reviews_booking_id  ON reviews(booking_id);

CREATE INDEX IF NOT EXISTS idx_payouts_fixer_id   ON payouts(fixer_id);
CREATE INDEX IF NOT EXISTS idx_payouts_status     ON payouts(status);
CREATE INDEX IF NOT EXISTS idx_payouts_hold_until ON payouts(hold_until) WHERE status = 'held';

CREATE INDEX IF NOT EXISTS idx_fixer_categories_fixer_id ON fixer_categories(fixer_id);
CREATE INDEX IF NOT EXISTS idx_fixer_categories_category ON fixer_categories(category);

CREATE INDEX IF NOT EXISTS idx_disputes_booking_id  ON disputes(booking_id);
CREATE INDEX IF NOT EXISTS idx_disputes_raised_by   ON disputes(raised_by);
CREATE INDEX IF NOT EXISTS idx_disputes_resolved_at ON disputes(resolved_at) WHERE resolved_at IS NULL;

-- Partial index for matching-eligible fixers (keeps index small and fast)
CREATE INDEX IF NOT EXISTS idx_fixers_available_active ON fixers(latitude, longitude)
  WHERE status = 'approved'
    AND available = true
    AND last_seen_at IS NOT NULL;

-- ═══════════════════════════════════════════════════════════════
-- AUTO-UPDATE updated_at TRIGGER
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_profiles_updated_at ON profiles;
CREATE TRIGGER update_profiles_updated_at  BEFORE UPDATE ON profiles  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
DROP TRIGGER IF EXISTS update_fixers_updated_at ON fixers;
CREATE TRIGGER update_fixers_updated_at    BEFORE UPDATE ON fixers    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
DROP TRIGGER IF EXISTS update_bookings_updated_at ON bookings;
CREATE TRIGGER update_bookings_updated_at  BEFORE UPDATE ON bookings  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
DROP TRIGGER IF EXISTS update_payments_updated_at ON payments;
CREATE TRIGGER update_payments_updated_at  BEFORE UPDATE ON payments  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ═══════════════════════════════════════════════════════════════
-- HELPER: single source of truth for commission rate
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION platform_commission_pct()
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 12.0;
$$;

-- ═══════════════════════════════════════════════════════════════
-- HELPER: validate booking state machine transitions
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION validate_booking_transition(
  old_status booking_status_enum,
  new_status booking_status_enum
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN (
    -- Normal forward flow
    (old_status = 'CREATED'             AND new_status = 'PENDING_PAYMENT') OR
    (old_status = 'PENDING_PAYMENT'     AND new_status = 'SEARCHING') OR
    (old_status = 'SEARCHING'           AND new_status = 'OFFERED') OR
    (old_status = 'OFFERED'             AND new_status = 'CONFIRMED') OR
    (old_status = 'OFFERED'             AND new_status = 'SEARCHING') OR  -- decline / expire
    (old_status = 'CONFIRMED'           AND new_status = 'EN_ROUTE') OR
    (old_status = 'EN_ROUTE'            AND new_status = 'ARRIVED') OR
    (old_status = 'ARRIVED'             AND new_status = 'IN_PROGRESS') OR
    (old_status = 'IN_PROGRESS'         AND new_status = 'PENDING_COMPLETION') OR
    (old_status = 'PENDING_COMPLETION'  AND new_status = 'COMPLETED') OR

    -- Dispute paths
    (old_status = 'CONFIRMED'           AND new_status = 'DISPUTED') OR
    (old_status = 'IN_PROGRESS'         AND new_status = 'DISPUTED') OR
    (old_status = 'PENDING_COMPLETION'  AND new_status = 'DISPUTED') OR
    -- resolve_dispute() outcomes
    (old_status = 'DISPUTED'            AND new_status = 'COMPLETED') OR
    (old_status = 'DISPUTED'            AND new_status = 'CANCELLED') OR

    -- Cancellation paths
    (old_status = 'PENDING_PAYMENT'     AND new_status = 'CANCELLED') OR
    (old_status = 'PENDING_PAYMENT'     AND new_status = 'EXPIRED') OR
    (old_status = 'SEARCHING'           AND new_status = 'CANCELLED') OR
    (old_status = 'OFFERED'             AND new_status = 'CANCELLED') OR
    (old_status = 'OFFERED'             AND new_status = 'EXPIRED') OR
    (old_status = 'CONFIRMED'           AND new_status = 'CANCELLED') OR
    (old_status = 'EN_ROUTE'            AND new_status = 'CANCELLED') OR  -- fixer abort
    (old_status = 'ARRIVED'             AND new_status = 'CANCELLED')
  );
END;
$$;

-- ═══════════════════════════════════════════════════════════════
-- HELPER: get fixer ID by user ID
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_fixer_id_by_user_id(p_user_id UUID)
RETURNS UUID AS $$
  SELECT id FROM fixers WHERE user_id = p_user_id AND status = 'approved' LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
