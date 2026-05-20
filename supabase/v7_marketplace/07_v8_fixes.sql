-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8 — TARGETED FIXES
-- Run AFTER 06_production_hardening.sql.
-- All statements are idempotent (safe to re-run).
--
-- FIX 3 — Push retry backpressure columns
-- FIX 4 — Health alert function (zero-cost: reuses WhatsApp nudge infra)
-- FIX 5 — Wallet double-credit uniqueness guard
-- FIX 6 — Cancellation reason tracking
-- ═══════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────
-- FIX 3: Push retry backpressure
-- Adds failed_attempts to fixer_nudges and customer_nudges so
-- process-nudges.js can abandon broken subscriptions after 3 tries
-- instead of retrying forever.
-- ───────────────────────────────────────────────────────────────

ALTER TABLE fixer_nudges
  ADD COLUMN IF NOT EXISTS failed_attempts INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS failed_permanently BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE customer_nudges
  ADD COLUMN IF NOT EXISTS failed_attempts INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS failed_permanently BOOLEAN NOT NULL DEFAULT false;

-- Helper RPC: increment failure count and mark permanent after threshold
DROP FUNCTION IF EXISTS increment_nudge_failure(UUID);
CREATE OR REPLACE FUNCTION increment_nudge_failure(p_nudge_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_attempts INTEGER;
BEGIN
  UPDATE fixer_nudges
  SET failed_attempts = failed_attempts + 1
  WHERE id = p_nudge_id
  RETURNING failed_attempts INTO v_attempts;

  IF v_attempts >= 3 THEN
    UPDATE fixer_nudges
    SET failed_permanently = true
    WHERE id = p_nudge_id;
  END IF;
END;
$$;

DROP FUNCTION IF EXISTS increment_customer_nudge_failure(UUID);
CREATE OR REPLACE FUNCTION increment_customer_nudge_failure(p_nudge_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_attempts INTEGER;
BEGIN
  UPDATE customer_nudges
  SET failed_attempts = failed_attempts + 1
  WHERE id = p_nudge_id
  RETURNING failed_attempts INTO v_attempts;

  IF v_attempts >= 3 THEN
    UPDATE customer_nudges
    SET failed_permanently = true
    WHERE id = p_nudge_id;
  END IF;
END;
$$;

-- Update get_pending_nudges to exclude permanently failed nudges
-- and expose failed_attempts so process-nudges.js can double-check
DROP FUNCTION IF EXISTS get_pending_nudges(INTEGER);
CREATE OR REPLACE FUNCTION get_pending_nudges(p_limit INTEGER DEFAULT 30)
RETURNS TABLE (
  nudge_id      UUID,
  nudge_source  TEXT,
  nudge_type    TEXT,
  target_id     UUID,
  user_id       UUID,
  payload       JSONB,
  failed_attempts INTEGER
)
LANGUAGE sql SECURITY DEFINER
AS $$
  -- Fixer drip nudges
  SELECT
    fn.id,
    'fixer'::TEXT,
    fn.nudge_type,
    fn.fixer_id,
    f.user_id,
    fn.payload,
    fn.failed_attempts
  FROM fixer_nudges fn
  JOIN fixers f ON f.id = fn.fixer_id
  WHERE fn.sent_at IS NULL
    AND fn.scheduled_for <= now()
    AND fn.failed_permanently = false
  UNION ALL
  -- Customer rebook nudges
  SELECT
    cn.id,
    'customer'::TEXT,
    'rebook_prompt',
    (cn.payload->>'booking_id')::UUID,
    cn.customer_id,
    cn.payload,
    cn.failed_attempts
  FROM customer_nudges cn
  WHERE cn.sent_at IS NULL
    AND cn.scheduled_for <= now()
    AND cn.failed_permanently = false
  ORDER BY 1
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION increment_nudge_failure(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION increment_customer_nudge_failure(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION get_pending_nudges(INTEGER) TO service_role;


-- ───────────────────────────────────────────────────────────────
-- FIX 4: Zero-cost health alerting
-- check_marketplace_health() runs daily (scheduled Netlify function)
-- and queues a WhatsApp nudge to the admin phone when thresholds breach.
-- Re-uses the existing WhatsApp infra — zero new infrastructure cost.
-- ───────────────────────────────────────────────────────────────

-- Admin contact table (one row, manually inserted after deploy)
CREATE TABLE IF NOT EXISTS admin_contacts (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  label       TEXT NOT NULL,           -- e.g. 'ops_lead'
  phone       TEXT NOT NULL,           -- E.164 format, e.g. '+27821234567'
  active      BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- Prevent duplicate inserts per label
CREATE UNIQUE INDEX IF NOT EXISTS admin_contacts_label_uidx ON admin_contacts(label) WHERE active = true;

-- Health alert RPC: called by the new Netlify health-alert.js function
-- Returns a list of alert messages to send, empty array if all healthy.
DROP FUNCTION IF EXISTS get_health_alerts(integer);

CREATE OR REPLACE FUNCTION get_health_alerts(p_days INTEGER DEFAULT 7)
RETURNS TABLE (
  metric      TEXT,
  value       NUMERIC,
  threshold   NUMERIC,
  message     TEXT
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_health          JSONB;
  v_match_rate      NUMERIC;
  v_completion_rate NUMERIC;
  v_median_to_match NUMERIC;
BEGIN
  SELECT get_marketplace_health(p_days) INTO v_health;

  v_match_rate      := (v_health->>'match_rate_pct')::NUMERIC;
  v_completion_rate := (v_health->>'completion_rate_pct')::NUMERIC;
  v_median_to_match := (v_health->>'median_seconds_to_match')::NUMERIC;

  IF (v_match_rate IS NOT NULL AND v_match_rate < 70) THEN
    RETURN QUERY SELECT
      'match_rate'::TEXT,
      v_match_rate,
      70::NUMERIC,
      format('⚠️ Servit alert: match rate is %s%% (target ≥70%%) over last %s days. Supply shortage likely.', ROUND(v_match_rate)::INTEGER, p_days);
  END IF;

  IF (v_completion_rate IS NOT NULL AND v_completion_rate < 80) THEN
    RETURN QUERY SELECT
      'completion_rate'::TEXT,
      v_completion_rate,
      80::NUMERIC,
      format('⚠️ Servit alert: completion rate is %s%% (target ≥80%%) over last %s days. Check fixer reliability.', ROUND(v_completion_rate)::INTEGER, p_days);
  END IF;

  IF (v_median_to_match IS NOT NULL AND v_median_to_match > 300) THEN
    RETURN QUERY SELECT
      'time_to_match'::TEXT,
      v_median_to_match,
      300::NUMERIC,
      format('⚠️ Servit alert: median time to match is %ss (target ≤300s). Dispatch may be too slow.', v_median_to_match::INTEGER);
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION get_health_alerts(INTEGER) TO service_role;

-- Seed your admin phone (run once manually, replace number):
-- INSERT INTO admin_contacts (label, phone) VALUES ('ops_lead', '+27821234567')
-- ON CONFLICT (label) WHERE active = true DO NOTHING;


-- ───────────────────────────────────────────────────────────────
-- FIX 5: Wallet double-credit uniqueness guard
-- Adds a unique constraint on (user_id, reason, related_id) in
-- wallet_transactions so two concurrent referral credits for the
-- same pair can't both commit, even if the advisory lock is bypassed.
-- The constraint is a belt-and-suspenders on top of pg_advisory_xact_lock.
-- ───────────────────────────────────────────────────────────────

-- Partial unique index: enforces one credit per (user, related referral/booking)
-- Only covers referral_bonus rows — other reasons (manual, loyalty) are unrestricted.
CREATE UNIQUE INDEX IF NOT EXISTS wallet_transactions_referral_uidx
  ON wallet_transactions (user_id, related_id)
  WHERE reason IN ('referral_bonus_referrer', 'referral_bonus_referee');

-- Update redeem_referral to handle the constraint gracefully
-- (catches unique_violation and returns the same "already redeemed" message)
DROP FUNCTION IF EXISTS redeem_referral(UUID, TEXT) CASCADE;
CREATE OR REPLACE FUNCTION redeem_referral(
  p_referee_id    UUID,
  p_referral_code TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_referrer_id        UUID;
  v_already_used       BOOLEAN;
  v_referee_bookings   INTEGER;
  v_credit_amount      NUMERIC := 50;
BEGIN
  -- Look up referrer
  SELECT id INTO v_referrer_id
  FROM profiles
  WHERE referral_code = p_referral_code;

  IF v_referrer_id IS NULL THEN
    RETURN jsonb_build_object('error', 'Referral code not found');
  END IF;

  -- Validate referee has completed at least 1 booking
  SELECT COUNT(*) INTO v_referee_bookings
  FROM bookings WHERE customer_id = p_referee_id AND status = 'COMPLETED';

  IF v_referee_bookings < 1 THEN
    RETURN jsonb_build_object('error', 'Referee has not completed a booking yet');
  END IF;

  -- Cannot self-refer
  IF v_referrer_id = p_referee_id THEN
    RETURN jsonb_build_object('error', 'Cannot use your own referral code');
  END IF;

  -- Advisory lock: prevents concurrent calls for the same referee
  IF NOT pg_try_advisory_xact_lock(hashtext(p_referee_id::TEXT)) THEN
    RETURN jsonb_build_object('error', 'Try again in a moment');
  END IF;

  -- Existence check after acquiring lock
  SELECT EXISTS(SELECT 1 FROM referrals WHERE referee_id = p_referee_id) INTO v_already_used;
  IF v_already_used THEN
    RETURN jsonb_build_object('error', 'Referral already redeemed');
  END IF;

  -- Record referral
  INSERT INTO referrals (referrer_id, referee_id, referral_code, credit_issued)
  VALUES (v_referrer_id, p_referee_id, p_referral_code, false);

  -- Credit wallets — unique index on wallet_transactions catches any remaining race
  BEGIN
    UPDATE profiles SET wallet_credit = GREATEST(0, wallet_credit + v_credit_amount)
    WHERE id IN (v_referrer_id, p_referee_id);

    INSERT INTO wallet_transactions (user_id, amount, reason, related_id) VALUES
      (v_referrer_id, v_credit_amount, 'referral_bonus_referrer', p_referee_id),
      (p_referee_id,  v_credit_amount, 'referral_bonus_referee',  v_referrer_id);
  EXCEPTION
    WHEN unique_violation THEN
      -- Concurrent call slipped through — treat as already redeemed
      RETURN jsonb_build_object('error', 'Referral already redeemed');
  END;

  UPDATE referrals SET credit_issued = true WHERE referee_id = p_referee_id;

  -- Notify both parties
  INSERT INTO notifications (user_id, title, body, type) VALUES
    (v_referrer_id,
     '🎉 Your referral worked!',
     'A friend used your referral code and booked their first job. R50 added to your wallet.',
     'referral_credited'),
    (p_referee_id,
     '🎁 R50 welcome credit!',
     'Your referral bonus has been added to your wallet. Use it on your next booking.',
     'referral_credited');

  RETURN jsonb_build_object(
    'ok', true,
    'referee_id',   p_referee_id,
    'referrer_id',  v_referrer_id,
    'credit_each',  v_credit_amount
  );
END;
$$;

GRANT EXECUTE ON FUNCTION redeem_referral(UUID, TEXT) TO authenticated, service_role;


-- ───────────────────────────────────────────────────────────────
-- FIX 6: Cancellation reason tracking
-- Adds cancellation_reason to bookings so quality gates and
-- fixer_performance can distinguish fixer no-shows from customer
-- cancels — giving surgical levers instead of blunt rate thresholds.
-- ───────────────────────────────────────────────────────────────

-- Reason enum (extendable — just add values as needed)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'cancellation_reason_type') THEN
    CREATE TYPE cancellation_reason_type AS ENUM (
      'customer_cancelled',    -- customer withdrew before fixer arrived
      'fixer_no_show',         -- fixer accepted but didn't arrive
      'fixer_cancelled',       -- fixer declined/cancelled after accepting
      'price_dispute',         -- agreed price vs actual price mismatch
      'no_fixer_available',    -- dispatch couldn't find a fixer in time
      'duplicate_booking',     -- customer accidentally double-booked
      'other'
    );
  END IF;
END;
$$;

ALTER TABLE bookings
  ADD COLUMN IF NOT EXISTS cancellation_reason cancellation_reason_type,
  ADD COLUMN IF NOT EXISTS cancellation_note   TEXT;  -- free-text (optional, admin use)

-- Updated fixer performance RPC that surfaces cancellation breakdown
DROP FUNCTION IF EXISTS get_fixer_performance(UUID, INTEGER);
CREATE OR REPLACE FUNCTION get_fixer_performance(p_fixer_id UUID, p_days INTEGER DEFAULT 30)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'fixer_id',            p_fixer_id,
    'period_days',         p_days,
    'total_assigned',      COUNT(*) FILTER (WHERE status IN ('OFFERED','ACCEPTED','COMPLETED','CANCELLED')),
    'completed',           COUNT(*) FILTER (WHERE status = 'COMPLETED'),
    'cancelled',           COUNT(*) FILTER (WHERE status = 'CANCELLED'),
    'completion_rate_pct', ROUND(
                             100.0 * COUNT(*) FILTER (WHERE status = 'COMPLETED') /
                             NULLIF(COUNT(*) FILTER (WHERE status IN ('ACCEPTED','COMPLETED','CANCELLED')), 0),
                           1),
    -- Cancellation breakdown — key diagnostic that was missing before FIX 6
    'cancellations_by_reason', (
      SELECT jsonb_object_agg(
        COALESCE(cancellation_reason::TEXT, 'unknown'),
        cnt
      )
      FROM (
        SELECT cancellation_reason, COUNT(*) AS cnt
        FROM bookings
        WHERE fixer_id = p_fixer_id
          AND status = 'CANCELLED'
          AND created_at >= now() - (p_days || ' days')::INTERVAL
        GROUP BY cancellation_reason
      ) cr
    ),
    'avg_rating',          ROUND(AVG(r.rating)::NUMERIC, 2),
    'review_count',        COUNT(DISTINCT r.id),
    'avg_response_secs',   ROUND(AVG(
                             EXTRACT(EPOCH FROM (b.accepted_at - b.offered_at))
                           ))
  ) INTO v_result
  FROM bookings b
  LEFT JOIN reviews r ON r.booking_id = b.id
  WHERE b.fixer_id = p_fixer_id
    AND b.created_at >= now() - (p_days || ' days')::INTERVAL;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_fixer_performance(UUID, INTEGER) TO service_role;

-- Convenience view for admin: cancellations split by who caused them
CREATE OR REPLACE VIEW cancellation_breakdown AS
SELECT
  DATE_TRUNC('week', created_at)::DATE             AS week,
  cancellation_reason,
  COUNT(*)                                          AS count,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY DATE_TRUNC('week', created_at)::DATE), 1) AS pct_of_week
FROM bookings
WHERE status = 'CANCELLED'
  AND cancellation_reason IS NOT NULL
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- ───────────────────────────────────────────────────────────────
-- POST-DEPLOY VERIFICATION
-- ───────────────────────────────────────────────────────────────
-- 1. Confirm new columns exist
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'fixer_nudges'
  AND column_name IN ('failed_attempts','failed_permanently');

-- 2. Test health alerts (should return empty if platform is healthy)
SELECT * FROM get_health_alerts(7);

-- 3. Confirm wallet uniqueness index
SELECT indexname FROM pg_indexes
WHERE tablename = 'wallet_transactions'
  AND indexname = 'wallet_transactions_referral_uidx';

-- 4. Confirm cancellation_reason column on bookings
SELECT column_name FROM information_schema.columns
WHERE table_name = 'bookings' AND column_name = 'cancellation_reason';

-- 5. Insert your admin phone (replace number, run once)
-- INSERT INTO admin_contacts (label, phone)
-- VALUES ('ops_lead', '+27821234567')
-- ON CONFLICT (label) WHERE active = true DO NOTHING;
