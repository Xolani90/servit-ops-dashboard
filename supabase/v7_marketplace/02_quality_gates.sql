-- ═══════════════════════════════════════════════════════════════
-- SERVIT v7.0 — QUALITY GATES
-- Feature 2: Ratings with teeth.
--   • Fixer below 4.0 after 10+ jobs → is_flagged = true, admin alert
--   • Fixer below 3.5 after 10+ jobs → status = 'suspended', auto_suspended_at
--   • Trigger fires after every review insert/update
--   • Admin can manually override via existing admin_override function
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Core quality-check function ──────────────────────────────
CREATE OR REPLACE FUNCTION check_fixer_quality(p_fixer_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fixer          fixers%ROWTYPE;
  v_action         TEXT := 'none';
  v_prev_status    TEXT;
  v_prev_flagged   BOOLEAN;
BEGIN
  SELECT * INTO v_fixer FROM fixers WHERE id = p_fixer_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'fixer not found'); END IF;

  v_prev_status  := v_fixer.status;
  v_prev_flagged := v_fixer.is_flagged;

  -- Need at least 10 reviewed jobs before quality gates apply
  IF COALESCE(v_fixer.review_count, 0) < 10 THEN
    RETURN jsonb_build_object('action', 'skipped', 'reason', 'insufficient_reviews',
      'review_count', v_fixer.review_count);
  END IF;

  -- ── GATE 1: below 3.5 → auto-suspend ─────────────────────────
  IF COALESCE(v_fixer.rating, 0) < 3.5 AND v_fixer.status != 'suspended' THEN
    UPDATE fixers SET
      status            = 'suspended',
      is_flagged        = true,
      flag_reason       = 'Auto-suspended: rating ' || ROUND(v_fixer.rating, 2)::TEXT || ' < 3.5 after ' || v_fixer.review_count || ' reviews',
      auto_suspended_at = now(),
      flagged_at        = COALESCE(v_fixer.flagged_at, now()),
      fixer_status      = 'offline',
      updated_at        = now()
    WHERE id = p_fixer_id;

    -- Notify fixer
    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT v_fixer.user_id,
      '⚠️ Account paused',
      'Your rating has dropped below our minimum threshold. Our team will review your account within 48 hours and contact you.',
      'account_action', p_fixer_id;

    -- Alert ALL admins
    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT p.id,
      '🚨 Fixer auto-suspended: ' || COALESCE(v_fixer.full_name, 'Unknown'),
      'Rating: ' || ROUND(v_fixer.rating, 2) || ' after ' || v_fixer.review_count ||
      ' reviews. Action required.',
      'admin_quality_alert', p_fixer_id
    FROM profiles p WHERE p.user_role = 'admin';

    v_action := 'suspended';

  -- ── GATE 2: below 4.0 → flag for review ──────────────────────
  ELSIF COALESCE(v_fixer.rating, 0) < 4.0 AND NOT COALESCE(v_fixer.is_flagged, false) THEN
    UPDATE fixers SET
      is_flagged  = true,
      flag_reason = 'Auto-flagged: rating ' || ROUND(v_fixer.rating, 2)::TEXT || ' < 4.0 after ' || v_fixer.review_count || ' reviews',
      flagged_at  = now(),
      updated_at  = now()
    WHERE id = p_fixer_id;

    -- Send fixer a constructive nudge, not a punishment message
    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT v_fixer.user_id,
      '📊 Your rating needs attention',
      'Your current rating is ' || ROUND(v_fixer.rating, 2) || '. Fixers with ratings above 4.0 get priority job offers. Tap to see tips.',
      'quality_nudge', p_fixer_id;

    -- Alert admins (lower priority than suspension)
    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT p.id,
      '⚠️ Fixer flagged: ' || COALESCE(v_fixer.full_name, 'Unknown'),
      'Rating: ' || ROUND(v_fixer.rating, 2) || ' after ' || v_fixer.review_count || ' reviews. Review recommended.',
      'admin_quality_flag', p_fixer_id
    FROM profiles p WHERE p.user_role = 'admin';

    v_action := 'flagged';

  -- ── GATE 3: recovered above 4.2 → auto-unflag ────────────────
  -- (Only unflag, never auto-unsuspend — that requires human review)
  ELSIF COALESCE(v_fixer.rating, 0) >= 4.2 AND COALESCE(v_fixer.is_flagged, false)
    AND v_fixer.status != 'suspended' THEN
    UPDATE fixers SET
      is_flagged  = false,
      flag_reason = NULL,
      updated_at  = now()
    WHERE id = p_fixer_id;

    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT v_fixer.user_id,
      '🌟 Great work!',
      'Your rating is back above 4.2. You''ll receive priority job offers again.',
      'quality_nudge', p_fixer_id;

    v_action := 'unflagged';
  END IF;

  RETURN jsonb_build_object(
    'action',          v_action,
    'fixer_id',        p_fixer_id,
    'rating',          v_fixer.rating,
    'review_count',    v_fixer.review_count,
    'prev_status',     v_prev_status,
    'prev_flagged',    v_prev_flagged
  );
END;
$$;

-- ── 2. Trigger: run quality check after each review ──────────────
-- Also updates completion_rate and response_time_avg from actual data
CREATE OR REPLACE FUNCTION after_review_update_fixer()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_avg_rating      NUMERIC;
  v_review_count    INTEGER;
  v_completion_rate NUMERIC;
  v_completed_jobs  INTEGER;
  v_accepted_jobs   INTEGER;
BEGIN
  -- Recalculate rating from all reviews (more accurate than running avg)
  SELECT AVG(rating), COUNT(*)
  INTO v_avg_rating, v_review_count
  FROM reviews
  WHERE fixer_id = NEW.fixer_id;

  -- Recalculate completion rate from bookings
  SELECT
    COUNT(*) FILTER (WHERE status = 'COMPLETED'),
    COUNT(*) FILTER (WHERE status IN ('COMPLETED', 'CANCELLED', 'DISPUTED'))
  INTO v_completed_jobs, v_accepted_jobs
  FROM bookings
  WHERE fixer_id = (SELECT id FROM fixers WHERE id = NEW.fixer_id);

  v_completion_rate := CASE
    WHEN COALESCE(v_accepted_jobs, 0) = 0 THEN 100
    ELSE ROUND((v_completed_jobs::NUMERIC / v_accepted_jobs) * 100, 1)
  END;

  UPDATE fixers SET
    rating          = ROUND(v_avg_rating, 2),
    review_count    = v_review_count,
    completion_rate = v_completion_rate,
    total_completed = COALESCE(v_completed_jobs, 0),
    updated_at      = now()
  WHERE id = NEW.fixer_id;

  -- Update profile last_booking stats for customer
  UPDATE profiles SET
    total_bookings   = total_bookings + CASE WHEN TG_OP = 'INSERT' THEN 1 ELSE 0 END,
    last_booking_at  = now()
  WHERE id = (SELECT customer_id FROM bookings WHERE id = NEW.booking_id);

  -- Run quality gate check
  PERFORM check_fixer_quality(NEW.fixer_id);

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_after_review ON reviews;
CREATE TRIGGER trg_after_review
  AFTER INSERT OR UPDATE ON reviews
  FOR EACH ROW EXECUTE FUNCTION after_review_update_fixer();

-- ── 3. Also update dispatch score — completion_rate feeds scoring ─
-- Patch the standard-tier scoring in build_dispatch_queue to use
-- the new completion_rate column directly (already present in v6.1
-- as acceptance_rate proxy — now we have the real number).
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

  -- ── SHARED SUBQUERY LOGIC (DRY via inline) ──────────────────
  -- Weighted score formula (same for all tiers, weights vary by tier):
  --   (rating/5 * W_rating) + (completion_rate/100 * W_completion)
  --   + (1 - response_time_avg/600 * W_speed) + (tier_verified * W_tier)

  IF v_tier = 'basic' THEN
    RETURN QUERY
    SELECT
      f.id,
      ROW_NUMBER() OVER (
        ORDER BY
          -- Primary: weighted marketplace score
          (
            COALESCE(f.rating, 3.0) / 5.0          * 0.4 +
            COALESCE(f.completion_rate, 100) / 100.0 * 0.3 +
            GREATEST(0, 1.0 - COALESCE(f.response_time_avg, 300) / 600.0) * 0.2 +
            COALESCE(f.price, 500) / 10000.0        * 0.1  -- cheaper = better for basic
          ) DESC,
          COALESCE(f.price, 9999) ASC
      )::INTEGER,
      (
        COALESCE(f.rating, 3.0) / 5.0           * 40 +
        COALESCE(f.completion_rate, 100) / 100.0 * 30 +
        GREATEST(0, 20 - COALESCE(f.response_time_avg, 300) / 15.0) +
        10 - LEAST(10, COALESCE(f.price, 500) / 100.0)
      )::NUMERIC AS score
    FROM fixers f
    WHERE f.status       = 'approved'
      AND f.fixer_status  = 'online'
      AND f.last_seen_at >= now() - interval '5 minutes'
      AND NOT COALESCE(f.is_flagged, false)   -- flagged fixers skip the queue
      AND (f.city = v_city OR (f.latitude IS NOT NULL AND v_lat IS NOT NULL))
      AND (
        v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id = f.id AND fc.category = v_booking.category)
      )
      AND NOT EXISTS (
        SELECT 1 FROM dispatch_log dl
        WHERE dl.booking_id = p_booking_id AND dl.fixer_id = f.id
          AND dl.status IN ('notified','accepted')
      )
    LIMIT 5;

  ELSIF v_tier = 'premium' THEN
    RETURN QUERY
    SELECT
      f.id,
      ROW_NUMBER() OVER (
        ORDER BY
          (
            COALESCE(f.rating, 3.0) / 5.0           * 0.4 +
            COALESCE(f.completion_rate, 100) / 100.0 * 0.3 +
            GREATEST(0, 1.0 - COALESCE(f.response_time_avg, 300) / 600.0) * 0.2 +
            CASE WHEN f.is_verified THEN 0.1 ELSE 0 END
          ) DESC
      )::INTEGER,
      (
        COALESCE(f.rating, 3.0) / 5.0           * 40 +
        COALESCE(f.completion_rate, 100) / 100.0 * 30 +
        GREATEST(0, 20 - COALESCE(f.response_time_avg, 300) / 15.0) +
        CASE WHEN f.is_verified THEN 10 ELSE 0 END
      )::NUMERIC AS score
    FROM fixers f
    WHERE f.status       = 'approved'
      AND f.fixer_status  = 'online'
      AND f.last_seen_at >= now() - interval '3 minutes'
      AND f.is_verified   = true
      AND NOT COALESCE(f.is_flagged, false)
      AND COALESCE(f.rating, 0)            >= 4.0
      AND COALESCE(f.completion_rate, 0)   >= 80
      AND (f.city = v_city OR (f.latitude IS NOT NULL AND v_lat IS NOT NULL))
      AND (
        v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id = f.id AND fc.category = v_booking.category)
      )
      AND NOT EXISTS (
        SELECT 1 FROM dispatch_log dl
        WHERE dl.booking_id = p_booking_id AND dl.fixer_id = f.id
      )
    LIMIT 8;

  ELSE -- standard (default)
    RETURN QUERY
    SELECT
      f.id,
      ROW_NUMBER() OVER (
        ORDER BY
          (
            COALESCE(f.rating, 3.0) / 5.0           * 0.4 +
            COALESCE(f.completion_rate, 100) / 100.0 * 0.3 +
            GREATEST(0, 1.0 - COALESCE(f.response_time_avg, 300) / 600.0) * 0.2 +
            -- Proximity bonus: closer fixers get up to 0.1 score
            CASE
              WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL THEN
                GREATEST(0, 0.1 - (2*6371*asin(sqrt(
                  power(sin(radians((f.latitude-v_lat)/2)),2)+
                  cos(radians(v_lat))*cos(radians(f.latitude))*
                  power(sin(radians((f.longitude-v_lng)/2)),2)
                ))) / 250.0)
              ELSE 0.05
            END
          ) DESC
      )::INTEGER,
      (
        COALESCE(f.rating, 3.0) / 5.0           * 40 +
        COALESCE(f.completion_rate, 100) / 100.0 * 30 +
        GREATEST(0, 20 - COALESCE(f.response_time_avg, 300) / 15.0) +
        CASE
          WHEN f.latitude IS NOT NULL AND v_lat IS NOT NULL THEN
            GREATEST(0, 10 - (2*6371*asin(sqrt(
              power(sin(radians((f.latitude-v_lat)/2)),2)+
              cos(radians(v_lat))*cos(radians(f.latitude))*
              power(sin(radians((f.longitude-v_lng)/2)),2)
            ))))
          ELSE 5
        END
      )::NUMERIC AS score
    FROM fixers f
    WHERE f.status       = 'approved'
      AND f.fixer_status  = 'online'
      AND f.last_seen_at >= now() - interval '4 minutes'
      AND NOT COALESCE(f.is_flagged, false)
      AND (f.city = v_city OR (f.latitude IS NOT NULL AND v_lat IS NOT NULL))
      AND (
        v_booking.category IS NULL
        OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
        OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id = f.id AND fc.category = v_booking.category)
      )
      AND NOT EXISTS (
        SELECT 1 FROM dispatch_log dl
        WHERE dl.booking_id = p_booking_id AND dl.fixer_id = f.id
      )
    LIMIT 6;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION check_fixer_quality(UUID) TO service_role;
GRANT EXECUTE ON FUNCTION build_dispatch_queue(UUID) TO service_role;
