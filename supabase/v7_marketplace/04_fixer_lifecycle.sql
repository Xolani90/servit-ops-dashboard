-- ═══════════════════════════════════════════════════════════════
-- SERVIT v7.0 — FIXER LIFECYCLE + REBOOK MECHANICS
-- Feature 3: Fixer supply drip + win celebration
-- Feature 4: Dormant fixer re-engagement
-- Feature 6: Referral + loyalty credit
-- Feature 4 (repeat): Post-job rebook prompt (server-side scheduling)
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Queue onboarding drip when fixer is approved ──────────────
DROP FUNCTION IF EXISTS queue_fixer_onboarding_drip(UUID) CASCADE;
CREATE OR REPLACE FUNCTION queue_fixer_onboarding_drip(p_fixer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Day 1: Welcome tip
  INSERT INTO fixer_nudges (fixer_id, nudge_type, scheduled_for, channel, payload)
  VALUES (
    p_fixer_id, 'day1_tip', now() + interval '1 hour', 'push',
    '{"title":"Welcome to Servit! 🎉","body":"First tip: keep your location ON and stay online to receive job offers near you."}'::JSONB
  )
  ON CONFLICT (fixer_id, nudge_type) DO NOTHING;

  -- Day 3: Photo nudge
  INSERT INTO fixer_nudges (fixer_id, nudge_type, scheduled_for, channel, payload)
  VALUES (
    p_fixer_id, 'day3_photo', now() + interval '3 days', 'push',
    '{"title":"Fixers with photos earn 40% more 📸","body":"Add a profile photo to build trust with customers and get more offers."}'::JSONB
  )
  ON CONFLICT (fixer_id, nudge_type) DO NOTHING;

  -- Day 7: First job encouragement (if no jobs yet)
  INSERT INTO fixer_nudges (fixer_id, nudge_type, scheduled_for, channel, payload)
  VALUES (
    p_fixer_id, 'day7_encourage', now() + interval '7 days', 'push',
    '{"title":"Stay online to get your first job 💪","body":"Fixers who stay online during peak hours (7am–9am, 5pm–8pm) get 3x more offers."}'::JSONB
  )
  ON CONFLICT (fixer_id, nudge_type) DO NOTHING;
END;
$$;

-- ── 2. Trigger: queue drip on fixer approval ─────────────────────
DROP FUNCTION IF EXISTS after_fixer_approved() CASCADE;
CREATE OR REPLACE FUNCTION after_fixer_approved()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status = 'approved' AND OLD.status != 'approved' THEN
    PERFORM queue_fixer_onboarding_drip(NEW.id);

    -- Immediate push notification
    INSERT INTO notifications (user_id, title, body, type, related_id)
    VALUES (
      NEW.user_id,
      '🎉 You''re approved! Start earning on Servit',
      'Go online now to start receiving job offers near you. Your first job is waiting!',
      'fixer_approved',
      NEW.id
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_after_fixer_approved ON fixers;
CREATE TRIGGER trg_after_fixer_approved
  AFTER UPDATE ON fixers
  FOR EACH ROW EXECUTE FUNCTION after_fixer_approved();

-- ── 3. First-job win celebration trigger ─────────────────────────
DROP FUNCTION IF EXISTS after_fixer_first_job() CASCADE;
CREATE OR REPLACE FUNCTION after_fixer_first_job()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fixer fixers%ROWTYPE;
BEGIN
  -- Fire when first_job_at transitions from NULL → value
  IF NEW.first_job_at IS NOT NULL AND OLD.first_job_at IS NULL THEN
    SELECT * INTO v_fixer FROM fixers WHERE id = NEW.id;

    -- In-app celebration notification
    INSERT INTO notifications (user_id, title, body, type, related_id)
    VALUES (
      NEW.user_id,
      '🏆 First job done — you''re a Servit fixer!',
      'Congratulations! You''ve completed your first job. Keep the momentum going — fixers who complete 5 jobs in their first month earn Top Fixer badge.',
      'win_celebration',
      NEW.id
    );

    -- Cancel the day7 encourage nudge since they've already succeeded
    UPDATE fixer_nudges SET sent_at = now()
    WHERE fixer_id = NEW.id AND nudge_type = 'day7_encourage' AND sent_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_fixer_first_job ON fixers;
CREATE TRIGGER trg_fixer_first_job
  AFTER UPDATE ON fixers
  FOR EACH ROW EXECUTE FUNCTION after_fixer_first_job();

-- ── 4. Dormant fixer detection RPC ───────────────────────────────
-- Called by Netlify scheduled function (daily).
-- Returns fixers who haven't been online in 7+ days.
DROP FUNCTION IF EXISTS get_dormant_fixers(INTEGER) CASCADE;
CREATE OR REPLACE FUNCTION get_dormant_fixers(p_days_offline INTEGER DEFAULT 7)
RETURNS TABLE(
  fixer_id    UUID,
  user_id     UUID,
  full_name   TEXT,
  phone       TEXT,
  city        TEXT,
  last_online TIMESTAMPTZ,
  days_offline INTEGER,
  demand_context TEXT  -- demand data for their city to use in message
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    f.id,
    f.user_id,
    f.full_name,
    f.phone,
    f.city,
    f.last_seen_at AS last_online,
    EXTRACT(DAY FROM now() - f.last_seen_at)::INTEGER AS days_offline,
    -- Count recent bookings in their city/category as demand signal for message
    (
      SELECT COUNT(b.id)::TEXT || ' jobs posted in ' || f.city || ' this week'
      FROM bookings b
      JOIN profiles p ON p.id = b.customer_id
      WHERE p.city = f.city
        AND b.created_at >= now() - interval '7 days'
        AND (
          f.category IS NULL
          OR b.category = f.category
          OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
          OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id = f.id AND fc.category = b.category)
        )
    ) AS demand_context
  FROM fixers f
  WHERE f.status = 'approved'
    AND (
      f.last_seen_at < now() - (p_days_offline || ' days')::INTERVAL
      OR f.last_seen_at IS NULL
    )
    -- Don't nudge suspended fixers
    AND f.status != 'suspended'
    -- Only nudge if we haven't sent a dormant nudge recently (within 7 days)
    AND NOT EXISTS (
      SELECT 1 FROM fixer_nudges fn
      WHERE fn.fixer_id = f.id
        AND fn.nudge_type = 'dormant'
        AND fn.sent_at >= now() - interval '7 days'
    )
  ORDER BY f.last_seen_at ASC NULLS FIRST
  LIMIT 50;  -- batch limit — process in chunks
END;
$$;

GRANT EXECUTE ON FUNCTION get_dormant_fixers(INTEGER) TO service_role;

-- ── 5. Mark dormant nudge sent ────────────────────────────────────
DROP FUNCTION IF EXISTS mark_nudge_sent(UUID, TEXT) CASCADE;
CREATE OR REPLACE FUNCTION mark_nudge_sent(p_fixer_id UUID, p_nudge_type TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO fixer_nudges (fixer_id, nudge_type, scheduled_for, sent_at, channel)
  VALUES (p_fixer_id, p_nudge_type, now(), now(), 'whatsapp')
  ON CONFLICT (fixer_id, nudge_type) DO UPDATE SET
    sent_at      = now(),
    scheduled_for = now();
END;
$$;

GRANT EXECUTE ON FUNCTION mark_nudge_sent(UUID, TEXT) TO service_role;

-- ── 6. Referral redemption RPC ────────────────────────────────────
-- Called when new user completes first booking with a referral code.
DROP FUNCTION IF EXISTS redeem_referral(UUID, TEXT) CASCADE;
CREATE OR REPLACE FUNCTION redeem_referral(
  p_referee_id   UUID,   -- new user
  p_referral_code TEXT   -- code they used at signup
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referrer_id   UUID;
  v_credit_amount NUMERIC := 50.00;  -- R50 each
  v_referee_bookings INTEGER;
BEGIN
  -- Validate referee has completed at least 1 booking
  SELECT COUNT(*) INTO v_referee_bookings
  FROM bookings WHERE customer_id = p_referee_id AND status = 'COMPLETED';

  IF v_referee_bookings < 1 THEN
    RETURN jsonb_build_object('error', 'Referee has not completed a booking yet');
  END IF;

  -- Find referrer by code
  SELECT id INTO v_referrer_id
  FROM profiles WHERE referral_code = p_referral_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Referral code not found');
  END IF;

  IF v_referrer_id = p_referee_id THEN
    RETURN jsonb_build_object('error', 'Cannot refer yourself');
  END IF;

  -- Insert referral record (UNIQUE on referee_id prevents double credit)
  INSERT INTO referrals (referrer_id, referee_id, referral_code, credit_issued)
  VALUES (v_referrer_id, p_referee_id, p_referral_code, false)
  ON CONFLICT (referee_id) DO NOTHING;

  -- If already credited, skip
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Referral already redeemed');
  END IF;

  -- Credit both parties
  UPDATE profiles SET wallet_credit = wallet_credit + v_credit_amount
  WHERE id IN (v_referrer_id, p_referee_id);

  INSERT INTO wallet_transactions (user_id, amount, reason, related_id)
  VALUES
    (v_referrer_id, v_credit_amount, 'referral_bonus_referrer', p_referee_id),
    (p_referee_id,  v_credit_amount, 'referral_bonus_referee',  v_referrer_id);

  UPDATE referrals SET credit_issued = true WHERE referee_id = p_referee_id;

  -- Notify both
  INSERT INTO notifications (user_id, title, body, type)
  VALUES
    (v_referrer_id, '🎁 R50 credit earned!',
     'A friend used your referral code and booked their first job. R50 added to your wallet.',
     'referral_credit'),
    (p_referee_id, '🎁 R50 welcome credit!',
     'Your referral bonus has been added to your wallet. Use it on your next booking.',
     'referral_credit');

  RETURN jsonb_build_object(
    'success',    true,
    'referrer_id', v_referrer_id,
    'referee_id',  p_referee_id,
    'credit_each', v_credit_amount
  );
END;
$$;

GRANT EXECUTE ON FUNCTION redeem_referral(UUID, TEXT) TO authenticated, service_role;

-- ── 7. Get pending nudges (called by Netlify scheduler) ──────────
DROP FUNCTION IF EXISTS get_pending_nudges(INTEGER) CASCADE;
CREATE OR REPLACE FUNCTION get_pending_nudges(p_limit INTEGER DEFAULT 20)
RETURNS TABLE(
  nudge_id    UUID,
  fixer_id    UUID,
  user_id     UUID,
  phone       TEXT,
  nudge_type  TEXT,
  channel     TEXT,
  payload     JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT fn.id, fn.fixer_id, f.user_id, f.phone, fn.nudge_type, fn.channel, fn.payload
  FROM fixer_nudges fn
  JOIN fixers f ON f.id = fn.fixer_id
  WHERE fn.sent_at IS NULL
    AND fn.scheduled_for <= now()
  ORDER BY fn.scheduled_for ASC
  LIMIT p_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION get_pending_nudges(INTEGER) TO service_role;

-- ── 8. Get rebook prompt data (customer-facing) ───────────────────
DROP FUNCTION IF EXISTS get_rebook_prompt(UUID) CASCADE;
CREATE OR REPLACE FUNCTION get_rebook_prompt(p_customer_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'fixer_id',    f.id,
    'full_name',   f.full_name,
    'photo_url',   f.photo_url,
    'rating',      f.rating,
    'category',    b.category,
    'is_online',   (f.fixer_status = 'online' AND f.last_seen_at >= now() - interval '5 minutes'),
    'booking_id',  b.id,
    'completed_at', b.completed_at
  )
  INTO v_result
  FROM bookings b
  JOIN fixers f ON f.id = b.fixer_id
  WHERE b.customer_id = p_customer_id
    AND b.status = 'COMPLETED'
    AND b.fixer_id IS NOT NULL
    -- Only show rebook prompt if last job was 18h–7 days ago (sweet spot)
    AND b.completed_at BETWEEN now() - interval '7 days' AND now() - interval '18 hours'
  ORDER BY b.completed_at DESC
  LIMIT 1;

  RETURN COALESCE(v_result, 'null'::JSONB);
END;
$$;

GRANT EXECUTE ON FUNCTION get_rebook_prompt(UUID) TO authenticated;
