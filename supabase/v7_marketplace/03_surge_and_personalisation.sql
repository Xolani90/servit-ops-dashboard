-- ═══════════════════════════════════════════════════════════════
-- SERVIT v7.0 — SURGE SIGNAL + HOME SCREEN PERSONALIZATION
-- Feature 2: Surge nudge to customer ("Fixers are busy — increase budget")
-- Feature 7: Personalised home screen (top category, last fixer, supply count)
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Surge signal RPC (callable from frontend) ─────────────────
-- Returns surge status for a given city + optional category.
-- Frontend calls this when customer opens the booking form.
CREATE OR REPLACE FUNCTION get_surge_signal(
  p_city     TEXT,
  p_category TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_searching   INTEGER;
  v_available   INTEGER;
  v_ratio       NUMERIC;
  v_is_surge    BOOLEAN;
  v_message     TEXT;
BEGIN
  -- Count active bookings needing fixers (demand)
  SELECT COUNT(DISTINCT b.id)
  INTO v_searching
  FROM bookings b
  JOIN profiles p ON p.id = b.customer_id
  WHERE b.status IN ('SEARCHING', 'OFFERED')
    AND p.city = p_city
    AND (p_category IS NULL OR b.category = p_category)
    AND b.created_at >= now() - interval '2 hours';

  -- Count available fixers (supply)
  SELECT COUNT(DISTINCT f.id)
  INTO v_available
  FROM fixers f
  WHERE f.city = p_city
    AND f.fixer_status = 'online'
    AND f.last_seen_at >= now() - interval '5 minutes'
    AND f.status = 'approved'
    AND NOT COALESCE(f.is_flagged, false)
    AND (
      p_category IS NULL
      OR NOT EXISTS (SELECT 1 FROM fixer_categories WHERE fixer_id = f.id)
      OR EXISTS (SELECT 1 FROM fixer_categories fc WHERE fc.fixer_id = f.id AND fc.category = p_category)
    );

  v_ratio := CASE
    WHEN COALESCE(v_available, 0) = 0 THEN 10
    ELSE ROUND(COALESCE(v_searching, 0)::NUMERIC / v_available, 2)
  END;

  v_is_surge := (v_ratio >= 2 OR v_available = 0);

  -- Honest, non-alarmist message
  IF v_available = 0 THEN
    v_message := 'No fixers online right now — a higher budget may bring one online faster.';
  ELSIF v_ratio >= 3 THEN
    v_message := 'Fixers are very busy right now. Increasing your budget will move you to the front of the queue.';
  ELSIF v_ratio >= 2 THEN
    v_message := 'Fixers are busy right now — increasing your budget can help you get matched faster.';
  ELSE
    v_message := NULL;  -- no surge, no message
  END IF;

  RETURN jsonb_build_object(
    'is_surge',           v_is_surge,
    'demand_ratio',       v_ratio,
    'searching_bookings', v_searching,
    'available_fixers',   v_available,
    'message',            v_message,
    'city',               p_city,
    'category',           p_category
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_surge_signal(TEXT, TEXT) TO anon, authenticated;

-- ── 2. Home screen personalisation RPC ───────────────────────────
-- Returns: top 3 categories for this customer (by booking frequency),
-- their last fixer (for quick rebook), and live supply counts.
-- Called every time the home screen loads — fast because it's indexed.
CREATE OR REPLACE FUNCTION get_home_personalisation(p_customer_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_city          TEXT;
  v_top_cats      JSONB;
  v_last_fixer    JSONB;
  v_supply_counts JSONB;
  v_booking_count INTEGER;
BEGIN
  -- Get customer city
  SELECT city INTO v_city FROM profiles WHERE id = p_customer_id;

  -- Only personalise after at least 2 completed bookings
  SELECT COUNT(*) INTO v_booking_count
  FROM bookings
  WHERE customer_id = p_customer_id AND status = 'COMPLETED';

  IF v_booking_count < 2 THEN
    RETURN jsonb_build_object('personalised', false, 'booking_count', v_booking_count);
  END IF;

  -- Top categories by frequency
  SELECT jsonb_agg(cat_data ORDER BY freq DESC)
  INTO v_top_cats
  FROM (
    SELECT
      category                                             AS cat_id,
      COUNT(*)                                             AS freq,
      MAX(created_at)                                      AS last_booked
    FROM bookings
    WHERE customer_id = p_customer_id
      AND status = 'COMPLETED'
      AND category IS NOT NULL
    GROUP BY category
    ORDER BY COUNT(*) DESC
    LIMIT 3
  ) sub
  CROSS JOIN LATERAL (
    SELECT jsonb_build_object(
      'id',        sub.category,
      'freq',      sub.freq,
      'last_booked', sub.last_booked
    ) AS cat_data
  ) _build;

  -- Last fixer (for quick rebook card)
  SELECT jsonb_build_object(
    'fixer_id',    f.id,
    'full_name',   f.full_name,
    'photo_url',   f.photo_url,
    'rating',      f.rating,
    'category',    f.category,
    'is_online',   (f.fixer_status = 'online' AND f.last_seen_at >= now() - interval '5 minutes'),
    'booking_id',  b.id
  )
  INTO v_last_fixer
  FROM bookings b
  JOIN fixers f ON f.id = b.fixer_id
  WHERE b.customer_id = p_customer_id
    AND b.status = 'COMPLETED'
    AND b.fixer_id IS NOT NULL
  ORDER BY b.completed_at DESC
  LIMIT 1;

  -- Live supply count per top category (for "N fixers near you" badge)
  SELECT jsonb_object_agg(cat, cnt)
  INTO v_supply_counts
  FROM (
    SELECT
      fc.category AS cat,
      COUNT(DISTINCT f.id) AS cnt
    FROM fixers f
    LEFT JOIN fixer_categories fc ON fc.fixer_id = f.id
    WHERE f.city = v_city
      AND f.fixer_status = 'online'
      AND f.last_seen_at >= now() - interval '5 minutes'
      AND f.status = 'approved'
    GROUP BY fc.category
  ) supply;

  RETURN jsonb_build_object(
    'personalised',    true,
    'booking_count',   v_booking_count,
    'top_categories',  COALESCE(v_top_cats, '[]'::JSONB),
    'last_fixer',      v_last_fixer,
    'supply_counts',   COALESCE(v_supply_counts, '{}'::JSONB),
    'city',            v_city
  );
END;
$$;

GRANT EXECUTE ON FUNCTION get_home_personalisation(UUID) TO authenticated;

-- ── 3. Update profile last_category + last_fixer on booking complete ─
CREATE OR REPLACE FUNCTION after_booking_completed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fixer_name TEXT;
BEGIN
  -- Only fire on transition to COMPLETED
  IF NEW.status = 'COMPLETED' AND OLD.status != 'COMPLETED' THEN

    -- Update customer profile
    SELECT full_name INTO v_fixer_name FROM fixers WHERE id = NEW.fixer_id;
    UPDATE profiles SET
      total_bookings   = total_bookings + 1,
      last_booking_at  = now(),
      last_category    = COALESCE(NEW.category, last_category),
      last_fixer_id    = COALESCE(NEW.fixer_id, last_fixer_id),
      last_fixer_name  = COALESCE(v_fixer_name, last_fixer_name)
    WHERE id = NEW.customer_id;

    -- Update fixer: set first_job_at on very first completed job
    UPDATE fixers SET
      total_completed = COALESCE(total_completed, 0) + 1,
      total_earnings  = COALESCE(total_earnings, 0) + COALESCE(NEW.commission, 0),
      first_job_at    = COALESCE(first_job_at, now()),  -- only sets once
      last_online_at  = now()
    WHERE id = NEW.fixer_id;

    -- Queue post-job rebook nudge for customer (24h later)
    INSERT INTO fixer_nudges (fixer_id, nudge_type, scheduled_for, channel, payload)
    -- Reuse the nudges table for customer nudges too (fixer_id = fixer for context)
    -- We use a separate approach: insert into notifications scheduled for 24h
    -- Actually, we'll insert a notification directly here.
    -- Separate rebook nudge via a Netlify scheduled function instead.
    SELECT f.id, 'post_job_rebook', now() + interval '23 hours', 'push',
      jsonb_build_object(
        'booking_id',   NEW.id,
        'customer_id',  NEW.customer_id,
        'fixer_name',   COALESCE(v_fixer_name, 'Your fixer'),
        'category',     NEW.category
      )
    FROM fixers f WHERE f.id = NEW.fixer_id
    ON CONFLICT (fixer_id, nudge_type) DO UPDATE SET
      scheduled_for = now() + interval '23 hours',
      payload = EXCLUDED.payload,
      sent_at = NULL;

  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_after_booking_completed ON bookings;
CREATE TRIGGER trg_after_booking_completed
  AFTER UPDATE ON bookings
  FOR EACH ROW EXECUTE FUNCTION after_booking_completed();
