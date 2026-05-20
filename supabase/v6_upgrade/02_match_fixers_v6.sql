-- ═══════════════════════════════════════════════════════════════
-- match_fixers — v6.0
-- Tier-aware adaptive matching with dispatch-first flow
--
-- BASIC tier:   50% price, 40% distance, 10% rating
-- STANDARD:     33% each (balanced)
-- PREMIUM:      50% rating, 30% response_time, 20% distance
--
-- Dispatch flow:
--   1. Score top fixers per tier weights
--   2. Notify top 3 simultaneously
--   3. First to accept wins
--   4. If no accept within dispatch_timeout → fallback to offer system
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION match_fixers(
  p_booking_id   UUID,
  p_radius_km    DOUBLE PRECISION DEFAULT 25.0,
  p_batch_size   INTEGER          DEFAULT 3
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking          bookings%ROWTYPE;
  v_fixer            RECORD;
  v_offer_id         UUID;
  v_offer_expires_at TIMESTAMPTZ;
  v_customer_lat     DOUBLE PRECISION;
  v_customer_lng     DOUBLE PRECISION;
  v_customer_city    TEXT;
  v_offers_sent      INTEGER := 0;
  v_first_offer_id   UUID;
  v_tier             service_tier_enum;
  v_timeout_secs     INTEGER;

  -- Tier scoring weights
  w_price     NUMERIC;
  w_distance  NUMERIC;
  w_rating    NUMERIC;
  w_response  NUMERIC;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Booking not found');
  END IF;

  IF v_booking.status != 'SEARCHING' OR v_booking.payment_status != 'paid' THEN
    RETURN jsonb_build_object('error', 'Booking not available for matching');
  END IF;

  -- Scheduled bookings: don't match until 2h before slot
  IF v_booking.booking_mode = 'scheduled'
     AND v_booking.scheduled_for > now() + interval '2 hours' THEN
    RETURN jsonb_build_object('error', 'Scheduled booking not ready for matching');
  END IF;

  v_customer_lat := v_booking.customer_latitude;
  v_customer_lng := v_booking.customer_longitude;
  v_tier         := COALESCE(v_booking.service_tier, 'standard');

  SELECT p.city INTO v_customer_city
  FROM profiles p WHERE p.id = v_booking.customer_id;

  -- ── Tier config ───────────────────────────────────────────
  CASE v_tier
    WHEN 'basic' THEN
      w_price    := 0.50;
      w_distance := 0.40;
      w_rating   := 0.10;
      w_response := 0.00;
      v_timeout_secs := 60;
    WHEN 'premium' THEN
      w_price    := 0.00;
      w_distance := 0.20;
      w_rating   := 0.50;
      w_response := 0.30;
      v_timeout_secs := 45;
    ELSE -- standard
      w_price    := 0.20;
      w_distance := 0.33;
      w_rating   := 0.33;
      w_response := 0.14;
      v_timeout_secs := 45;
  END CASE;

  v_offer_expires_at := now() + (v_timeout_secs || ' seconds')::interval;

  -- ── Update booking with dispatch info ──────────────────────
  UPDATE bookings SET
    dispatch_at     = now(),
    dispatch_expiry = v_offer_expires_at
  WHERE id = p_booking_id;

  -- ── Score and select fixers ────────────────────────────────
  FOR v_fixer IN
    WITH scored_fixers AS (
      SELECT
        f.*,
        -- Distance score (0–1, lower is better → inverted)
        CASE
          WHEN f.latitude IS NOT NULL AND f.longitude IS NOT NULL
               AND v_customer_lat IS NOT NULL AND v_customer_lng IS NOT NULL
          THEN
            GREATEST(0, 1.0 - (
              2 * 6371 * asin(sqrt(
                power(sin(radians((f.latitude  - v_customer_lat)  / 2)), 2) +
                cos(radians(v_customer_lat)) *
                cos(radians(f.latitude)) *
                power(sin(radians((f.longitude - v_customer_lng) / 2)), 2)
              ))
            ) / p_radius_km)
          ELSE 0.5  -- neutral if no geo
        END AS distance_score,

        -- Rating score (0–1)
        COALESCE(f.rating, 3.0) / 5.0 AS rating_score,

        -- Response time score (0–1, lower seconds = better)
        CASE
          WHEN f.response_time_avg IS NOT NULL
          THEN GREATEST(0, 1.0 - (f.response_time_avg::NUMERIC / 300))  -- 300s = worst
          ELSE 0.5
        END AS response_score,

        -- Price proxy: lower hourly rate = better for basic
        -- Use acceptance_rate as proxy (low acceptance = higher effective price pressure)
        COALESCE(f.acceptance_rate, 80) / 100.0 AS price_score,

        -- Hard penalties
        CASE WHEN f.acceptance_rate < 60 THEN 0.5 ELSE 1.0 END AS penalty,
        CASE WHEN v_tier = 'premium' AND NOT f.is_verified THEN 0.7 ELSE 1.0 END AS verified_bonus

      FROM fixers f
      WHERE f.status      = 'approved'
        AND f.fixer_status = 'online'      -- v6.0: use fixer_status not available
        AND f.last_seen_at >= now() - interval '3 minutes'
        AND (
          (f.latitude IS NOT NULL AND f.longitude IS NOT NULL)
          OR f.city = v_customer_city
        )
        AND (
          v_booking.category IS NULL
          OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
          OR EXISTS (
            SELECT 1 FROM fixer_categories fc
            WHERE fc.fixer_id = f.id AND fc.category = v_booking.category
          )
        )
        AND NOT EXISTS (
          SELECT 1 FROM offers o
          WHERE o.booking_id = v_booking.id
            AND o.fixer_id   = f.id
            AND o.status     IN ('declined', 'expired')
        )
        -- Premium: skip unverified fixers unless none available
        AND (
          v_tier != 'premium'
          OR f.is_verified = true
          OR NOT EXISTS (
            SELECT 1 FROM fixers f2
            WHERE f2.status = 'approved' AND f2.fixer_status = 'online'
              AND f2.is_verified = true AND f2.city = v_customer_city
          )
        )
    )
    SELECT *,
      (
        (distance_score * w_distance) +
        (rating_score   * w_rating)   +
        (response_score * w_response) +
        (price_score    * w_price)
      ) * penalty * verified_bonus AS match_score
    FROM scored_fixers
    ORDER BY match_score DESC
    LIMIT p_batch_size
  LOOP
    INSERT INTO offers (booking_id, fixer_id, expires_at)
    VALUES (v_booking.id, v_fixer.id, v_offer_expires_at)
    ON CONFLICT (booking_id, fixer_id) DO NOTHING
    RETURNING id INTO v_offer_id;

    IF v_offer_id IS NOT NULL THEN
      v_offers_sent := v_offers_sent + 1;

      IF v_first_offer_id IS NULL THEN
        v_first_offer_id := v_offer_id;
      END IF;

      -- Log dispatch
      INSERT INTO dispatch_log (booking_id, fixer_id, status, score, tier)
      VALUES (v_booking.id, v_fixer.id, 'notified', v_fixer.match_score, v_tier);

      -- Tier-aware notification message
      INSERT INTO notifications (user_id, title, body, type, related_id)
      VALUES (
        v_fixer.user_id,
        CASE v_tier
          WHEN 'premium' THEN '⭐ Premium job offer!'
          WHEN 'basic'   THEN '💼 Job near you!'
          ELSE                '🔔 New job offer!'
        END,
        'A client needs ' ||
          COALESCE(v_booking.category, 'help') ||
          CASE v_tier
            WHEN 'premium' THEN ' · Premium client · Accept fast!'
            WHEN 'basic'   THEN ' · Accept within ' || v_timeout_secs || 's.'
            ELSE                ' · Accept within ' || v_timeout_secs || 's.'
          END,
        'job_offer',
        v_offer_id
      );

      INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata)
      VALUES (
        v_booking.id, 'offer_created', 'SEARCHING', 'OFFERED',
        jsonb_build_object(
          'fixer_id',       v_fixer.id,
          'offer_id',       v_offer_id,
          'tier',           v_tier,
          'match_score',    v_fixer.match_score,
          'match_method',   CASE WHEN v_customer_lat IS NOT NULL THEN 'geo' ELSE 'city_text' END,
          'batch_position', v_offers_sent
        )
      );
    END IF;
  END LOOP;

  -- ── No fixers available ────────────────────────────────────
  IF v_offers_sent = 0 THEN
    -- Broadcast to offline fixers
    INSERT INTO notifications (user_id, title, body, type, related_id)
    SELECT
      f.user_id,
      '💼 Job available near you!',
      'A client needs ' ||
        COALESCE(v_booking.category, 'help') ||
        COALESCE(' in ' || v_customer_city, ' in your area') ||
        '. Go online to accept.',
      'demand_alert',
      v_booking.id
    FROM fixers f
    WHERE f.status = 'approved'
      AND f.city = v_customer_city
      AND NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.user_id    = f.user_id
          AND n.related_id = v_booking.id
          AND n.type       = 'demand_alert'
      );

    RETURN jsonb_build_object(
      'error',      'No fixers available',
      'broadcast',  true,
      'booking_id', v_booking.id,
      'tier',       v_tier
    );
  END IF;

  UPDATE bookings SET
    status           = 'OFFERED',
    offered_at       = now(),
    current_offer_id = v_first_offer_id,
    offer_expires_at = v_offer_expires_at,
    updated_at       = now(),
    version          = version + 1
  WHERE id = v_booking.id;

  RETURN jsonb_build_object(
    'success',      true,
    'booking_id',   v_booking.id,
    'status',       'OFFERED',
    'offers_sent',  v_offers_sent,
    'expires_at',   v_offer_expires_at,
    'tier',         v_tier,
    'dispatch_mode','auto'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION match_fixers(UUID, DOUBLE PRECISION, INTEGER) TO service_role;
