-- ═══════════════════════════════════════════════════════════════
-- SERVIT v5.2 — Row Level Security Policies
-- Changes from v5.1:
--   FIX 6: bookings table RLS enabled — customers/fixers can only
--           read their own bookings. Previously no RLS existed on
--           bookings, meaning any authenticated user could read any
--           booking via direct REST calls.
-- ═══════════════════════════════════════════════════════════════

-- ── PROFILES ─────────────────────────────────────────────────
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profiles_select_own ON profiles;
DROP POLICY IF EXISTS profiles_update_own ON profiles;

CREATE POLICY profiles_select_own ON profiles
  FOR SELECT USING (auth.uid() = id OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.user_role = 'admin'));

CREATE POLICY profiles_update_own ON profiles
  FOR UPDATE USING (auth.uid() = id);

-- ── FIXERS ───────────────────────────────────────────────────
ALTER TABLE fixers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fixers_select_public ON fixers;
DROP POLICY IF EXISTS fixers_update_own    ON fixers;
DROP POLICY IF EXISTS fixers_insert_own    ON fixers;

-- Anyone can read fixer profiles (needed for matching display, reviews, map pins)
CREATE POLICY fixers_select_public ON fixers
  FOR SELECT USING (true);

-- Fixers update their own row — available column guarded separately by trigger
CREATE POLICY fixers_update_own ON fixers
  FOR UPDATE USING (auth.uid() = user_id);

-- ── BOOKINGS ─────────────────────────────────────────────────
-- FIX 6: Enable RLS on bookings
ALTER TABLE bookings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bookings_select_own       ON bookings;
DROP POLICY IF EXISTS bookings_insert_own       ON bookings;
DROP POLICY IF EXISTS bookings_no_direct_update ON bookings;
DROP POLICY IF EXISTS bookings_no_direct_delete ON bookings;

-- Customers see their own; fixers see assigned bookings; admins see all
CREATE POLICY bookings_select_own ON bookings
  FOR SELECT
  USING (
    customer_id = auth.uid()
    OR fixer_id IN (SELECT id FROM fixers WHERE user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND user_role = 'admin')
  );

-- Customers create bookings for themselves
CREATE POLICY bookings_insert_own ON bookings
  FOR INSERT
  WITH CHECK (customer_id = auth.uid());

-- All mutations go through SECURITY DEFINER functions.
-- The prevent_booking_status_update trigger enforces this at DB level.
-- These policies add a REST-layer block.
CREATE POLICY bookings_no_direct_update ON bookings
  FOR UPDATE USING (false);

CREATE POLICY bookings_no_direct_delete ON bookings
  FOR DELETE USING (false);

-- ── PAYMENTS ─────────────────────────────────────────────────
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS payments_select_own ON payments;

CREATE POLICY payments_select_own ON payments
  FOR SELECT USING (
    auth.uid() = (SELECT customer_id FROM bookings WHERE id = booking_id)
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND user_role = 'admin')
  );

-- ── OFFERS ───────────────────────────────────────────────────
ALTER TABLE offers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS offers_select_fixer   ON offers;
DROP POLICY IF EXISTS offers_select_customer ON offers;

CREATE POLICY offers_select_fixer ON offers
  FOR SELECT USING (
    fixer_id IN (SELECT id FROM fixers WHERE user_id = auth.uid())
    OR auth.uid() = (SELECT customer_id FROM bookings WHERE id = booking_id)
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND user_role = 'admin')
  );

-- ── REVIEWS ──────────────────────────────────────────────────
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS reviews_select_public   ON reviews;
DROP POLICY IF EXISTS reviews_insert_customer ON reviews;

CREATE POLICY reviews_select_public ON reviews FOR SELECT USING (true);
CREATE POLICY reviews_insert_customer ON reviews
  FOR INSERT WITH CHECK (auth.uid() = reviewer_id);

-- ── PAYOUTS ──────────────────────────────────────────────────
ALTER TABLE payouts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS payouts_select_fixer ON payouts;

CREATE POLICY payouts_select_fixer ON payouts
  FOR SELECT USING (
    auth.uid() = (SELECT user_id FROM fixers WHERE id = fixer_id)
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND user_role = 'admin')
  );

-- ── FIXER CATEGORIES ─────────────────────────────────────────
ALTER TABLE fixer_categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fixer_categories_select     ON fixer_categories;
DROP POLICY IF EXISTS fixer_categories_insert_own ON fixer_categories;
DROP POLICY IF EXISTS fixer_categories_delete_own ON fixer_categories;

CREATE POLICY fixer_categories_select ON fixer_categories FOR SELECT USING (true);

CREATE POLICY fixer_categories_insert_own ON fixer_categories
  FOR INSERT WITH CHECK (auth.uid() = (SELECT user_id FROM fixers WHERE id = fixer_id));

CREATE POLICY fixer_categories_delete_own ON fixer_categories
  FOR DELETE USING (auth.uid() = (SELECT user_id FROM fixers WHERE id = fixer_id));

-- ── DISPUTES ─────────────────────────────────────────────────
ALTER TABLE disputes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS disputes_select_parties ON disputes;
DROP POLICY IF EXISTS disputes_insert_parties ON disputes;
DROP POLICY IF EXISTS disputes_update_admin   ON disputes;

CREATE POLICY disputes_select_parties ON disputes
  FOR SELECT USING (
    auth.uid() = raised_by
    OR auth.uid() = (SELECT customer_id FROM bookings WHERE id = booking_id)
    OR auth.uid() = (SELECT user_id FROM fixers WHERE id =
        (SELECT fixer_id FROM bookings WHERE id = booking_id))
    OR EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND user_role = 'admin')
  );

CREATE POLICY disputes_insert_parties ON disputes
  FOR INSERT WITH CHECK (auth.uid() = raised_by);

CREATE POLICY disputes_update_admin ON disputes
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND user_role = 'admin')
  );

-- ── NOTIFICATIONS ─────────────────────────────────────────────
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notifications_select_own  ON notifications;
DROP POLICY IF EXISTS notifications_update_own  ON notifications;

CREATE POLICY notifications_select_own ON notifications
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY notifications_update_own ON notifications
  FOR UPDATE USING (auth.uid() = user_id);

-- ── MESSAGES ─────────────────────────────────────────────────
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS messages_select_parties ON messages;
DROP POLICY IF EXISTS messages_insert_own     ON messages;

CREATE POLICY messages_select_parties ON messages
  FOR SELECT USING (auth.uid() = sender_id OR auth.uid() = receiver_id);

CREATE POLICY messages_insert_own ON messages
  FOR INSERT WITH CHECK (auth.uid() = sender_id);
