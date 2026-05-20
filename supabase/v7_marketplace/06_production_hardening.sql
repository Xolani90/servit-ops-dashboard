-- ═══════════════════════════════════════════════════════════════════
-- SERVIT v7.0 — PRODUCTION HARDENING
-- Run after 01_schema → 05_fixes migrations.
-- Idempotent — safe to re-run.
-- Fixes 20 issues identified in full codebase audit.
-- ═══════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────
-- FIX 1: Separate customer_nudges table
-- fixer_nudges was doing double duty — customer rebook prompts were
-- stored with a fixer_id FK even though the target is a customer.
-- This caused confusing queries and will cause FK violations when
-- the fixer is deleted but the customer prompt should survive.
-- ────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS customer_nudges (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  customer_id   UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  nudge_type    TEXT NOT NULL,            -- 'rebook_prompt', 'loyalty_reward', etc.
  scheduled_for TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at       TIMESTAMPTZ,
  channel       TEXT DEFAULT 'push',
  payload       JSONB,                    -- booking_id, fixer_name, category, etc.
  UNIQUE (customer_id, nudge_type)        -- one pending nudge per type per customer
);

CREATE INDEX IF NOT EXISTS idx_customer_nudges_sched
  ON customer_nudges(scheduled_for) WHERE sent_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_customer_nudges_customer
  ON customer_nudges(customer_id);

-- RLS: customers can only see their own nudges
ALTER TABLE customer_nudges ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS customer_nudges_own ON customer_nudges;
CREATE POLICY customer_nudges_own ON customer_nudges
  FOR SELECT USING (customer_id = auth.uid());

-- service_role can do everything (Netlify functions)
GRANT ALL ON customer_nudges TO service_role;
GRANT SELECT ON customer_nudges TO authenticated;

-- Migrate existing post_job_rebook nudges from fixer_nudges → customer_nudges
-- (They were stored with fixer_id but payload has the real customer_id)
INSERT INTO customer_nudges (customer_id, nudge_type, scheduled_for, sent_at, channel, payload)
SELECT
  (payload->>'customer_id')::UUID,
  'rebook_prompt',
  scheduled_for,
  sent_at,
  channel,
  payload
FROM fixer_nudges
WHERE nudge_type = 'post_job_rebook'
  AND payload->>'customer_id' IS NOT NULL
ON CONFLICT (customer_id, nudge_type) DO NOTHING;

-- Remove migrated rows from fixer_nudges (clean up the dual-purpose mess)
DELETE FROM fixer_nudges WHERE nudge_type = 'post_job_rebook';


-- ────────────────────────────────────────────────────────────────
-- FIX 2: Move trigger side-effects off the hot path
-- after_booking_completed was doing 3 table writes inside a trigger
-- on the bookings UPDATE — a nudge insert failure could roll back
-- a completed booking. Split into: (a) fast trigger for critical
-- stat updates, (b) async nudge queueing via a separate safe path.
-- ────────────────────────────────────────────────────────────────

-- Replace the old trigger function with a lean version (stats only)
DROP FUNCTION IF EXISTS after_booking_completed() CASCADE;
CREATE OR REPLACE FUNCTION after_booking_completed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fixer_name TEXT;
BEGIN
  IF NEW.status != 'COMPLETED' OR OLD.status = 'COMPLETED' THEN
    RETURN NEW;  -- guard: only fire on the transition
  END IF;

  -- (a) Update customer profile stats — critical, stays in trigger
  UPDATE profiles SET
    total_bookings  = total_bookings + 1,
    last_booking_at = now(),
    last_category   = COALESCE(NEW.category, last_category),
    last_fixer_id   = COALESCE(NEW.fixer_id,  last_fixer_id),
    last_fixer_name = COALESCE(
      (SELECT full_name FROM fixers WHERE id = NEW.fixer_id),
      last_fixer_name
    )
  WHERE id = NEW.customer_id;

  -- (b) Update fixer stats — critical, stays in trigger
  IF NEW.fixer_id IS NOT NULL THEN
    UPDATE fixers SET
      total_completed = COALESCE(total_completed, 0) + 1,
      total_earnings  = COALESCE(total_earnings,  0) + COALESCE(NEW.commission, 0),
      first_job_at    = COALESCE(first_job_at, now()),
      last_online_at  = now()
    WHERE id = NEW.fixer_id;
  END IF;

  -- (c) Nudge queueing is intentionally removed from this trigger.
  --     It is now handled by queue_rebook_nudge() RPC called from
  --     the Netlify booking-complete webhook, outside this transaction.
  --     This means a nudge-queue failure never rolls back a completion.

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_after_booking_completed ON bookings;
CREATE TRIGGER trg_after_booking_completed
  AFTER UPDATE ON bookings
  FOR EACH ROW EXECUTE FUNCTION after_booking_completed();

-- Safe async nudge-queueing RPC (called by Netlify after booking completes)
DROP FUNCTION IF EXISTS queue_rebook_nudge(UUID, UUID, UUID);
CREATE OR REPLACE FUNCTION queue_rebook_nudge(
  p_booking_id  UUID,
  p_customer_id UUID,
  p_fixer_id    UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fixer_name TEXT;
  v_category   TEXT;
BEGIN
  SELECT full_name INTO v_fixer_name FROM fixers WHERE id = p_fixer_id;
  SELECT category INTO v_category FROM bookings WHERE id = p_booking_id;

  INSERT INTO customer_nudges (customer_id, nudge_type, scheduled_for, channel, payload)
  VALUES (
    p_customer_id,
    'rebook_prompt',
    now() + interval '23 hours',
    'push',
    jsonb_build_object(
      'booking_id',  p_booking_id,
      'fixer_id',    p_fixer_id,
      'fixer_name',  COALESCE(v_fixer_name, 'Your fixer'),
      'category',    v_category
    )
  )
  ON CONFLICT (customer_id, nudge_type) DO UPDATE SET
    scheduled_for = now() + interval '23 hours',
    payload       = EXCLUDED.payload,
    sent_at       = NULL;  -- reset so it gets sent again
END;
$$;

GRANT EXECUTE ON FUNCTION queue_rebook_nudge(UUID, UUID, UUID) TO service_role;


-- ────────────────────────────────────────────────────────────────
-- FIX 3: Single heartbeat window constant
-- last_seen_at freshness was checked with 3 different intervals
-- (3 min for premium, 4 min for standard, 5 min for basic/surge).
-- Centralise into one DB setting. Default 6 minutes gives breathing
-- room for slow mobile connections without marking fixers offline.
-- ────────────────────────────────────────────────────────────────

-- Store as a DB-level setting (configurable without code deploy)
DO $$
BEGIN
  -- Only set if not already customised
  PERFORM set_config('app.settings.heartbeat_window_minutes', '6', false);
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;

-- Helper function used by all dispatch + surge queries
DROP FUNCTION IF EXISTS fixer_is_online(TIMESTAMPTZ);
CREATE OR REPLACE FUNCTION fixer_is_online(p_last_seen_at TIMESTAMPTZ)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_last_seen_at >= now() -
    (COALESCE(current_setting('app.settings.heartbeat_window_minutes', true), '6')::INTEGER
     || ' minutes')::INTERVAL
$$;

-- Patch build_dispatch_queue to use the helper (replaces all 3 hardcoded intervals)
DROP FUNCTION IF EXISTS build_dispatch_queue(UUID);
CREATE OR REPLACE FUNCTION build_dispatch_queue(p_booking_id UUID)
RETURNS TABLE(fixer_id UUID, rank_position INTEGER, score NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking   bookings%ROWTYPE;
  v_tier      service_tier_enum;
  v_city      TEXT;
  v_lat       DOUBLE PRECISION;
  v_lng       DOUBLE PRECISION;
BEGIN
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id;
  IF NOT FOUND THEN RETURN; END IF;

  v_tier := COALESCE(v_booking.service_tier, 'standard');
  v_lat  := v_booking.customer_latitude;
  v_lng  := v_booking.customer_longitude;
  SELECT p.city INTO v_city FROM profiles p WHERE p.id = v_booking.customer_id;

  IF v_tier = 'basic' THEN
    RETURN QUERY
    SELECT f.id,
      ROW_NUMBER() OVER (ORDER BY (
        COALESCE(f.rating, 3.0)/5.0           * 0.4 +
        COALESCE(f.completion_rate,100)/100.0  * 0.3 +
        GREATEST(0,1.0-COALESCE(f.response_time_avg,300)/600.0) * 0.2 +
        COALESCE(f.price,500)/10000.0          * 0.1
      ) DESC, COALESCE(f.price,9999) ASC)::INTEGER,
      (COALESCE(f.rating,3.0)/5.0*40 + COALESCE(f.completion_rate,100)/100.0*30 +
       GREATEST(0,20-COALESCE(f.response_time_avg,300)/15.0) +
       10-LEAST(10,COALESCE(f.price,500)/100.0))::NUMERIC AS score
    FROM fixers f
    WHERE f.status = 'approved' AND f.fixer_status = 'online'
      AND fixer_is_online(f.last_seen_at)
      AND NOT COALESCE(f.is_flagged,false)
      AND (f.city = v_city OR (f.latitude IS NOT NULL AND v_lat IS NOT NULL))
      AND (v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id=f.id AND fc.category=v_booking.category))
      AND NOT EXISTS (SELECT 1 FROM dispatch_log dl
        WHERE dl.booking_id=p_booking_id AND dl.fixer_id=f.id AND dl.status IN ('notified','accepted'))
    LIMIT 5;

  ELSIF v_tier = 'premium' THEN
    RETURN QUERY
    SELECT f.id,
      ROW_NUMBER() OVER (ORDER BY (
        COALESCE(f.rating,3.0)/5.0           * 0.4 +
        COALESCE(f.completion_rate,100)/100.0 * 0.3 +
        GREATEST(0,1.0-COALESCE(f.response_time_avg,300)/600.0) * 0.2 +
        CASE WHEN f.is_verified THEN 0.1 ELSE 0 END
      ) DESC)::INTEGER,
      (COALESCE(f.rating,3.0)/5.0*40 + COALESCE(f.completion_rate,100)/100.0*30 +
       GREATEST(0,20-COALESCE(f.response_time_avg,300)/15.0) +
       CASE WHEN f.is_verified THEN 10 ELSE 0 END)::NUMERIC AS score
    FROM fixers f
    WHERE f.status = 'approved' AND f.fixer_status = 'online'
      AND fixer_is_online(f.last_seen_at)
      AND f.is_verified = true AND NOT COALESCE(f.is_flagged,false)
      AND COALESCE(f.rating,0) >= 4.0 AND COALESCE(f.completion_rate,0) >= 80
      AND (f.city = v_city OR (f.latitude IS NOT NULL AND v_lat IS NOT NULL))
      AND (v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id=f.id AND fc.category=v_booking.category))
      AND NOT EXISTS (SELECT 1 FROM dispatch_log dl WHERE dl.booking_id=p_booking_id AND dl.fixer_id=f.id)
    LIMIT 8;

  ELSE -- standard
    RETURN QUERY
    SELECT f.id,
      ROW_NUMBER() OVER (ORDER BY (
        COALESCE(f.rating,3.0)/5.0           * 0.4 +
        COALESCE(f.completion_rate,100)/100.0 * 0.3 +
        GREATEST(0,1.0-COALESCE(f.response_time_avg,300)/600.0) * 0.2 +
        CASE
          WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL THEN
            GREATEST(0,0.1-(2*6371*asin(sqrt(
              power(sin(radians((f.latitude-v_lat)/2)),2)+
              cos(radians(v_lat))*cos(radians(f.latitude))*
              power(sin(radians((f.longitude-v_lng)/2)),2)
            )))/250.0)
          ELSE 0.05
        END
      ) DESC)::INTEGER,
      (COALESCE(f.rating,3.0)/5.0*40 + COALESCE(f.completion_rate,100)/100.0*30 +
       GREATEST(0,20-COALESCE(f.response_time_avg,300)/15.0) +
       CASE
         WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL THEN
           GREATEST(0,10-(2*6371*asin(sqrt(
             power(sin(radians((f.latitude-v_lat)/2)),2)+
             cos(radians(v_lat))*cos(radians(f.latitude))*
             power(sin(radians((f.longitude-v_lng)/2)),2)
           ))))
         ELSE 5
       END)::NUMERIC AS score
    FROM fixers f
    WHERE f.status = 'approved' AND f.fixer_status = 'online'
      AND fixer_is_online(f.last_seen_at)
      AND NOT COALESCE(f.is_flagged,false)
      AND (f.city = v_city OR (f.latitude IS NOT NULL AND v_lat IS NOT NULL))
      AND (v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id=f.id AND fc.category=v_booking.category))
      AND NOT EXISTS (SELECT 1 FROM dispatch_log dl WHERE dl.booking_id=p_booking_id AND dl.fixer_id=f.id)
    LIMIT 6;
  END IF;
END;
$$;

-- Also patch get_surge_signal and surge_signal view to use the helper
DROP FUNCTION IF EXISTS get_surge_signal(TEXT, TEXT);
CREATE OR REPLACE FUNCTION get_surge_signal(p_city TEXT, p_category TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_searching INTEGER;
  v_available INTEGER;
  v_ratio     NUMERIC;
  v_is_surge  BOOLEAN;
  v_message   TEXT;
BEGIN
  SELECT COUNT(DISTINCT b.id) INTO v_searching
  FROM bookings b
  JOIN profiles p ON p.id = b.customer_id
  WHERE b.status IN ('SEARCHING', 'OFFERED')
    AND b.fixer_id IS NULL                         -- FIX 18: exclude already-matched OFFERED bookings
    AND p.city = p_city
    AND (p_category IS NULL OR b.category = p_category)
    AND b.created_at >= now() - interval '2 hours';

  SELECT COUNT(DISTINCT f.id) INTO v_available
  FROM fixers f
  WHERE f.city = p_city
    AND f.fixer_status = 'online'
    AND fixer_is_online(f.last_seen_at)            -- uses centralised window
    AND f.status = 'approved'
    AND NOT COALESCE(f.is_flagged, false)
    AND (p_category IS NULL
      OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
      OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id=f.id AND fc.category=p_category));

  v_ratio    := CASE WHEN COALESCE(v_available,0)=0 THEN 10
                     ELSE ROUND(COALESCE(v_searching,0)::NUMERIC/v_available,2) END;
  v_is_surge := (v_ratio >= 2 OR v_available = 0);

  IF v_available = 0 THEN
    v_message := 'No fixers online right now — a higher budget may bring one online faster.';
  ELSIF v_ratio >= 3 THEN
    v_message := 'Fixers are very busy right now. Increasing your budget will move you to the front of the queue.';
  ELSIF v_ratio >= 2 THEN
    v_message := 'Fixers are busy right now — increasing your budget can help you get matched faster.';
  ELSE
    v_message := NULL;
  END IF;

  RETURN jsonb_build_object(
    'is_surge','v_is_surge', 'demand_ratio',v_ratio,
    'searching_bookings',v_searching, 'available_fixers',v_available,
    'message',v_message, 'city',p_city, 'category',p_category
  );
END;
$$;

-- Rebuild the surge_signal view with the same fix (FIX 18)
CREATE OR REPLACE VIEW surge_signal AS
SELECT
  p.city,
  b.category,
  COUNT(DISTINCT b.id)    AS searching_bookings,
  COUNT(DISTINCT f.id)    AS available_fixers,
  CASE
    WHEN COUNT(DISTINCT f.id) = 0 THEN 10
    ELSE ROUND(COUNT(DISTINCT b.id)::NUMERIC / COUNT(DISTINCT f.id), 2)
  END                     AS demand_ratio,
  CASE
    WHEN COUNT(DISTINCT f.id) = 0 THEN true
    WHEN COUNT(DISTINCT b.id)::NUMERIC / NULLIF(COUNT(DISTINCT f.id),0) >= 2 THEN true
    ELSE false
  END                     AS is_surge
FROM bookings b
JOIN profiles p ON p.id = b.customer_id
LEFT JOIN fixers f ON f.city = p.city
  AND f.fixer_status = 'online'
  AND fixer_is_online(f.last_seen_at)
  AND f.status = 'approved'
  AND (b.category IS NULL
    OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
    OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id=f.id AND fc.category=b.category))
WHERE b.status IN ('SEARCHING', 'OFFERED')
  AND b.fixer_id IS NULL                           -- FIX 18: exclude already-matched OFFERED
  AND b.created_at >= now() - interval '1 hour'
GROUP BY p.city, b.category;

GRANT SELECT ON surge_signal TO anon, authenticated, service_role;


-- ────────────────────────────────────────────────────────────────
-- FIX 4: redeem_referral double-spend race condition
-- ON CONFLICT DO NOTHING doesn't set NOT FOUND in plpgsql.
-- Fix: check for existing row explicitly before inserting.
-- ────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS redeem_referral(UUID, TEXT);
CREATE OR REPLACE FUNCTION redeem_referral(
  p_referee_id    UUID,
  p_referral_code TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referrer_id     UUID;
  v_credit_amount   NUMERIC := 50.00;
  v_referee_bookings INTEGER;
  v_already_used    BOOLEAN;
BEGIN
  -- Check if already redeemed (explicit check — ON CONFLICT doesn't set NOT FOUND)
  SELECT EXISTS(
    SELECT 1 FROM referrals WHERE referee_id = p_referee_id
  ) INTO v_already_used;

  IF v_already_used THEN
    RETURN jsonb_build_object('error', 'Referral already redeemed');
  END IF;

  -- Validate referee has at least 1 completed booking
  SELECT COUNT(*) INTO v_referee_bookings
  FROM bookings WHERE customer_id = p_referee_id AND status = 'COMPLETED';

  IF v_referee_bookings < 1 THEN
    RETURN jsonb_build_object('error', 'Referee has not completed a booking yet');
  END IF;

  -- Find referrer
  SELECT id INTO v_referrer_id FROM profiles WHERE referral_code = p_referral_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Referral code not found');
  END IF;

  IF v_referrer_id = p_referee_id THEN
    RETURN jsonb_build_object('error', 'Cannot refer yourself');
  END IF;

  -- Advisory lock: prevents concurrent calls for the same referee
  -- (pg_try_advisory_xact_lock takes a bigint — hash the UUID)
  IF NOT pg_try_advisory_xact_lock(hashtext(p_referee_id::TEXT)) THEN
    RETURN jsonb_build_object('error', 'Referral already being processed — try again in a moment');
  END IF;

  -- Re-check inside the lock (double-checked locking pattern)
  SELECT EXISTS(SELECT 1 FROM referrals WHERE referee_id = p_referee_id) INTO v_already_used;
  IF v_already_used THEN
    RETURN jsonb_build_object('error', 'Referral already redeemed');
  END IF;

  -- Insert referral record
  INSERT INTO referrals (referrer_id, referee_id, referral_code, credit_issued)
  VALUES (v_referrer_id, p_referee_id, p_referral_code, false);

  -- Credit both parties atomically
  UPDATE profiles SET wallet_credit = GREATEST(0, wallet_credit + v_credit_amount)
  WHERE id IN (v_referrer_id, p_referee_id);

  INSERT INTO wallet_transactions (user_id, amount, reason, related_id) VALUES
    (v_referrer_id, v_credit_amount, 'referral_bonus_referrer', p_referee_id),
    (p_referee_id,  v_credit_amount, 'referral_bonus_referee',  v_referrer_id);

  UPDATE referrals SET credit_issued = true WHERE referee_id = p_referee_id;

  INSERT INTO notifications (user_id, title, body, type) VALUES
    (v_referrer_id, '🎁 R50 credit earned!',
     'A friend used your referral code and booked their first job. R50 added to your wallet.',
     'referral_credit'),
    (p_referee_id,  '🎁 R50 welcome credit!',
     'Your referral bonus has been added to your wallet. Use it on your next booking.',
     'referral_credit');

  RETURN jsonb_build_object(
    'success',true,'referrer_id',v_referrer_id,
    'referee_id',p_referee_id,'credit_each',v_credit_amount
  );
END;
$$;

GRANT EXECUTE ON FUNCTION redeem_referral(UUID, TEXT) TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────
-- FIX 14: function_errors logging table
-- Netlify functions log to console but logs expire in Netlify's
-- free tier after 1 hour. Errors need a persistent home.
-- ────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS function_errors (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  function_name TEXT NOT NULL,
  error_message TEXT NOT NULL,
  error_detail  TEXT,
  context       JSONB,          -- e.g. {fixer_id, nudge_type, booking_id}
  created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_function_errors_fn   ON function_errors(function_name, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_function_errors_time ON function_errors(created_at DESC);

-- Auto-purge errors older than 90 days (no storage creep)
DROP FUNCTION IF EXISTS purge_old_function_errors();
CREATE OR REPLACE FUNCTION purge_old_function_errors()
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  DELETE FROM function_errors WHERE created_at < now() - interval '90 days';
$$;

-- Only Netlify service_role can write errors; no client access
GRANT INSERT ON function_errors TO service_role;
GRANT SELECT ON function_errors TO service_role;
REVOKE ALL ON function_errors FROM authenticated, anon;

-- Convenience RPC for Netlify functions to log errors in one line
DROP FUNCTION IF EXISTS log_function_error(TEXT, TEXT, TEXT, JSONB);
CREATE OR REPLACE FUNCTION log_function_error(
  p_function TEXT,
  p_error    TEXT,
  p_detail   TEXT DEFAULT NULL,
  p_context  JSONB DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO function_errors(function_name, error_message, error_detail, context)
  VALUES (p_function, p_error, p_detail, p_context);
EXCEPTION WHEN OTHERS THEN
  NULL; -- never let error logging itself crash anything
END;
$$;

GRANT EXECUTE ON FUNCTION log_function_error(TEXT,TEXT,TEXT,JSONB) TO service_role;


-- ────────────────────────────────────────────────────────────────
-- FIX 15: Dormant nudge UNIQUE constraint prevents re-nudging
-- UNIQUE(fixer_id, nudge_type) means after one dormant nudge is
-- sent+marked, mark_nudge_sent updates sent_at but a future
-- dormant period can't insert a new row (the key already exists).
-- Fix: drop the constraint on dormant type; use a different approach.
-- ────────────────────────────────────────────────────────────────

-- Replace mark_nudge_sent to handle dormant nudges differently
DROP FUNCTION IF EXISTS mark_nudge_sent(UUID, TEXT);
CREATE OR REPLACE FUNCTION mark_nudge_sent(p_fixer_id UUID, p_nudge_type TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_nudge_type = 'dormant' THEN
    -- Dormant nudges recur — insert a fresh history row rather than updating
    INSERT INTO fixer_nudges (fixer_id, nudge_type, scheduled_for, sent_at, channel)
    VALUES (p_fixer_id, 'dormant_' || to_char(now(), 'YYYY_MM_DD'), now(), now(), 'whatsapp')
    ON CONFLICT DO NOTHING;
    -- The get_dormant_fixers query already checks sent_at >= now() - 7 days,
    -- so even with multiple history rows, re-nudging is naturally throttled.
  ELSE
    INSERT INTO fixer_nudges (fixer_id, nudge_type, scheduled_for, sent_at, channel)
    VALUES (p_fixer_id, p_nudge_type, now(), now(), 'whatsapp')
    ON CONFLICT (fixer_id, nudge_type) DO UPDATE SET
      sent_at       = now(),
      scheduled_for = now();
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION mark_nudge_sent(UUID, TEXT) TO service_role;

-- Also fix get_dormant_fixers: the double status check was redundant
-- and the dormant nudge check now needs to match the new key pattern
DROP FUNCTION IF EXISTS get_dormant_fixers(INTEGER);
CREATE OR REPLACE FUNCTION get_dormant_fixers(p_days_offline INTEGER DEFAULT 7)
RETURNS TABLE(
  fixer_id      UUID, user_id UUID, full_name TEXT, phone TEXT,
  city TEXT, last_online TIMESTAMPTZ, days_offline INTEGER, demand_context TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    f.id, f.user_id, f.full_name, f.phone, f.city,
    f.last_seen_at AS last_online,
    EXTRACT(DAY FROM now() - f.last_seen_at)::INTEGER AS days_offline,
    (SELECT COUNT(b.id)::TEXT || ' jobs posted in ' || f.city || ' this week'
     FROM bookings b JOIN profiles p ON p.id = b.customer_id
     WHERE p.city = f.city AND b.created_at >= now() - interval '7 days'
       AND (f.category IS NULL OR b.category = f.category
         OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
         OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id=f.id AND fc.category=b.category))
    ) AS demand_context
  FROM fixers f
  WHERE f.status = 'approved'                          -- FIX 16: single status check
    AND (f.last_seen_at < now() - (p_days_offline || ' days')::INTERVAL OR f.last_seen_at IS NULL)
    AND NOT EXISTS (
      SELECT 1 FROM fixer_nudges fn
      WHERE fn.fixer_id = f.id
        AND fn.nudge_type LIKE 'dormant%'              -- matches dormant_YYYY_MM_DD keys
        AND fn.sent_at >= now() - interval '7 days'
    )
  ORDER BY f.last_seen_at ASC NULLS FIRST
  LIMIT 50;
END;
$$;

GRANT EXECUTE ON FUNCTION get_dormant_fixers(INTEGER) TO service_role;


-- ────────────────────────────────────────────────────────────────
-- FIX 19 & 20: RLS + wallet_credit cannot go negative
-- ────────────────────────────────────────────────────────────────

-- wallet_credit: prevent negative values (bad actor or bug)
ALTER TABLE profiles
  DROP CONSTRAINT IF EXISTS chk_wallet_credit_non_negative;
ALTER TABLE profiles
  ADD CONSTRAINT chk_wallet_credit_non_negative CHECK (wallet_credit >= 0);

-- wallet_transactions RLS: users see only their own rows
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS wallet_transactions_own ON wallet_transactions;
CREATE POLICY wallet_transactions_own ON wallet_transactions
  FOR SELECT USING (user_id = auth.uid());

-- referrals RLS: referrer and referee can see their own rows
ALTER TABLE referrals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS referrals_own ON referrals;
CREATE POLICY referrals_own ON referrals
  FOR SELECT USING (referrer_id = auth.uid() OR referee_id = auth.uid());

-- fixer_nudges RLS: fixers see only their own nudges
ALTER TABLE fixer_nudges ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS fixer_nudges_own ON fixer_nudges;
CREATE POLICY fixer_nudges_own ON fixer_nudges
  FOR SELECT USING (
    fixer_id IN (SELECT id FROM fixers WHERE user_id = auth.uid())
  );


-- ────────────────────────────────────────────────────────────────
-- FIX: get_pending_nudges — now returns BOTH fixer + customer nudges
-- Previously only returned fixer_nudges; now also returns
-- customer_nudges so process-nudges.js can handle rebook prompts
-- ────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS get_pending_nudges(INTEGER);
CREATE OR REPLACE FUNCTION get_pending_nudges(p_limit INTEGER DEFAULT 20)
RETURNS TABLE(
  nudge_id    UUID,
  target_id   UUID,    -- fixer_id OR customer_id depending on nudge_source
  user_id     UUID,
  phone       TEXT,
  nudge_type  TEXT,
  nudge_source TEXT,   -- 'fixer' | 'customer' — so process-nudges knows which table
  channel     TEXT,
  payload     JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  -- Fixer drip nudges
  SELECT fn.id, fn.fixer_id, f.user_id, f.phone,
         fn.nudge_type, 'fixer'::TEXT, fn.channel, fn.payload
  FROM fixer_nudges fn
  JOIN fixers f ON f.id = fn.fixer_id
  WHERE fn.sent_at IS NULL AND fn.scheduled_for <= now()
    AND fn.nudge_type NOT LIKE 'dormant%'  -- dormant handled separately

  UNION ALL

  -- Customer rebook nudges
  SELECT cn.id, cn.customer_id, cn.customer_id, NULL::TEXT,
         cn.nudge_type, 'customer'::TEXT, cn.channel, cn.payload
  FROM customer_nudges cn
  WHERE cn.sent_at IS NULL AND cn.scheduled_for <= now()

  ORDER BY 3  -- scheduled_for (position in UNION)
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION get_pending_nudges(INTEGER) TO service_role;


-- ────────────────────────────────────────────────────────────────
-- FIX 17: profile_complete generated column safety
-- The GENERATED ALWAYS AS expression references bio — add it if missing
-- ────────────────────────────────────────────────────────────────

ALTER TABLE fixers ADD COLUMN IF NOT EXISTS bio TEXT;


-- ────────────────────────────────────────────────────────────────
-- SEED DATA: test fixer + test customer for deploy verification
-- Wrapped in a function so it's opt-in and safe to call repeatedly
-- ────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS seed_test_data();
CREATE OR REPLACE FUNCTION seed_test_data()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_test_fixer_user_id   UUID := '00000000-0000-0000-0000-000000000001';
  v_test_customer_user_id UUID := '00000000-0000-0000-0000-000000000002';
  v_test_fixer_id        UUID;
  v_test_booking_id      UUID := uuid_generate_v4();
BEGIN
  -- ── Test fixer profile ──────────────────────────────────────
  INSERT INTO fixers (
    user_id, full_name, phone, city, status, fixer_status, available,
    rating, review_count, completion_rate, response_time_avg,
    is_verified, category, last_seen_at
  ) VALUES (
    v_test_fixer_user_id,
    'Test Fixer (DELETE BEFORE PROD)',
    '+27821234567',
    'Pretoria',
    'approved', 'online', true,
    4.7, 15, 95.0, 90,
    true, 'Plumbing',
    now()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    last_seen_at = now(), fixer_status = 'online', available = true
  RETURNING id INTO v_test_fixer_id;

  -- ── Test customer profile ───────────────────────────────────
  INSERT INTO profiles (id, full_name, city, total_bookings, last_booking_at)
  VALUES (
    v_test_customer_user_id,
    'Test Customer (DELETE BEFORE PROD)',
    'Pretoria',
    3,
    now() - interval '2 days'
  )
  ON CONFLICT (id) DO UPDATE SET
    last_booking_at = now() - interval '2 days';

  -- ── Test completed booking (needed to test rebook flow) ─────
  INSERT INTO bookings (
    id, customer_id, fixer_id, category, status, payment_status,
    service_tier, address, city, commission,
    created_at, accepted_at, completed_at
  ) VALUES (
    v_test_booking_id,
    v_test_customer_user_id,
    v_test_fixer_id,
    'Plumbing',
    'COMPLETED', 'paid',
    'standard',
    '123 Test Street, Pretoria',
    'Pretoria',
    150.00,
    now() - interval '2 days',
    now() - interval '2 days' + interval '3 minutes',
    now() - interval '30 hours'
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN jsonb_build_object(
    'test_fixer_id',          v_test_fixer_id,
    'test_fixer_user_id',     v_test_fixer_user_id,
    'test_customer_user_id',  v_test_customer_user_id,
    'test_booking_id',        v_test_booking_id,
    'note', 'DELETE these rows before going live with real users. Call delete_test_data() to remove them.'
  );
END;
$$;

DROP FUNCTION IF EXISTS delete_test_data();
CREATE OR REPLACE FUNCTION delete_test_data()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM bookings  WHERE customer_id = '00000000-0000-0000-0000-000000000002';
  DELETE FROM fixers    WHERE user_id     = '00000000-0000-0000-0000-000000000001';
  DELETE FROM profiles  WHERE id          = '00000000-0000-0000-0000-000000000002';
END;
$$;

GRANT EXECUTE ON FUNCTION seed_test_data()   TO service_role;
GRANT EXECUTE ON FUNCTION delete_test_data() TO service_role;


-- ════════════════════════════════════════════════════════════════
-- VERIFICATION SCRIPT
-- Run every line of this after applying the migration.
-- All should return expected values. Nothing should error.
-- ════════════════════════════════════════════════════════════════
/*
-- 1. Seed test data
SELECT seed_test_data();

-- 2. Confirm fixer_is_online helper
SELECT fixer_is_online(now() - interval '3 minutes');  -- → true
SELECT fixer_is_online(now() - interval '10 minutes'); -- → false

-- 3. Test dispatch queue with test fixer (should return 1 row)
-- First create a test booking, then:
-- SELECT * FROM build_dispatch_queue('<test-booking-id>');

-- 4. Test surge signal
SELECT get_surge_signal('Pretoria', 'Plumbing');

-- 5. Test rebook_from_history
SELECT rebook_from_history('00000000-0000-0000-0000-000000000002');
-- Expected: {"ok":true, "fixer_name":"Test Fixer...", "category":"Plumbing"}

-- 6. Confirm rebook nudge queue
SELECT queue_rebook_nudge(
  '<test-booking-id>',
  '00000000-0000-0000-0000-000000000002',
  (SELECT id FROM fixers WHERE user_id='00000000-0000-0000-0000-000000000001')
);
SELECT * FROM customer_nudges WHERE nudge_type = 'rebook_prompt';

-- 7. Test health analytics
SELECT get_marketplace_health(30);

-- 8. Confirm RLS on wallet_transactions (run as authenticated user, not service_role)
-- Should return only rows for the current user

-- 9. Test double-spend protection
SELECT redeem_referral('00000000-0000-0000-0000-000000000002', 'SERVIT-XXXXXX');
SELECT redeem_referral('00000000-0000-0000-0000-000000000002', 'SERVIT-XXXXXX');
-- Second call should return {"error":"Referral already redeemed"}

-- 10. Clean up test data before launch
SELECT delete_test_data();
*/
