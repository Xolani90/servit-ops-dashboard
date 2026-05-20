-- ═══════════════════════════════════════════════════════════════
-- SERVIT v6.1 — PATCH 4+5
-- Trust badges + enhanced manual operations
-- ═══════════════════════════════════════════════════════════════

-- ── Badge columns ──────────────────────────────────────────────
ALTER TABLE fixers
  ADD COLUMN IF NOT EXISTS badge_fast_responder BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS badge_top_fixer      BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS badges_updated_at    TIMESTAMPTZ;

-- ── Badge assignment rules ─────────────────────────────────────
-- Fast Responder: avg_response_time <= 30s AND total_accepted >= 5
-- Top Fixer:      completion_rate >= 90 AND rating >= 4.5 AND total_completed >= 10
-- Verified:       is_verified = true (admin-set manually)

CREATE OR REPLACE FUNCTION assign_fixer_badges(p_fixer_id UUID DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
BEGIN
  UPDATE fixers SET
    badge_fast_responder = (
      COALESCE(avg_response_time, 9999) <= 30
      AND total_accepted >= 5
    ),
    badge_top_fixer = (
      COALESCE(completion_rate, 0) >= 90
      AND COALESCE(rating, 0)      >= 4.5
      AND total_completed          >= 10
    ),
    badges_updated_at = now()
  WHERE (p_fixer_id IS NULL OR id = p_fixer_id)
    AND status = 'approved';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Run badge assignment after metrics update
CREATE OR REPLACE FUNCTION trigger_assign_badges()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IN ('COMPLETED','CANCELLED')
     AND OLD.status NOT IN ('COMPLETED','CANCELLED')
     AND NEW.fixer_id IS NOT NULL THEN
    PERFORM assign_fixer_badges(NEW.fixer_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_assign_badges ON bookings;
CREATE TRIGGER trg_assign_badges
  AFTER UPDATE ON bookings
  FOR EACH ROW
  EXECUTE FUNCTION trigger_assign_badges();

-- ── Enhanced admin_dashboard with stuck job details ───────────
CREATE OR REPLACE FUNCTION admin_dashboard()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN jsonb_build_object(
    'bookings', jsonb_build_object(
      'searching',   (SELECT count(*) FROM bookings WHERE status = 'SEARCHING'),
      'offered',     (SELECT count(*) FROM bookings WHERE status = 'OFFERED'),
      'confirmed',   (SELECT count(*) FROM bookings WHERE status = 'CONFIRMED'),
      'in_progress', (SELECT count(*) FROM bookings WHERE status = 'IN_PROGRESS'),
      'today',       (SELECT count(*) FROM bookings WHERE created_at > now() - interval '24 hours'),
      'stuck',       (SELECT count(*) FROM bookings
                      WHERE status IN ('SEARCHING','OFFERED')
                        AND updated_at < now() - interval '5 minutes')
    ),
    'fixers', jsonb_build_object(
      'online',          (SELECT count(*) FROM fixers WHERE fixer_status = 'online'),
      'busy',            (SELECT count(*) FROM fixers WHERE fixer_status = 'busy'),
      'offline',         (SELECT count(*) FROM fixers WHERE fixer_status = 'offline'),
      'top_fixers',      (SELECT count(*) FROM fixers WHERE badge_top_fixer = true),
      'fast_responders', (SELECT count(*) FROM fixers WHERE badge_fast_responder = true),
      'verified',        (SELECT count(*) FROM fixers WHERE is_verified = true)
    ),
    'revenue', jsonb_build_object(
      'today', COALESCE((SELECT sum(platform_fee) FROM payouts WHERE created_at > now() - interval '24 hours'), 0),
      'week',  COALESCE((SELECT sum(platform_fee) FROM payouts WHERE created_at > now() - interval '7 days'), 0)
    ),
    'stuck_jobs', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',               b.id,
        'status',           b.status,
        'tier',             b.service_tier,
        'category',         b.category,
        'dispatch_sequence',b.dispatch_sequence,
        'priority',         b.priority_flag,
        'minutes_stuck',    ROUND(EXTRACT(EPOCH FROM (now() - b.updated_at))/60),
        'created_at',       b.created_at
      ) ORDER BY b.updated_at ASC), '[]'::JSONB)
      FROM bookings b
      WHERE b.status IN ('SEARCHING','OFFERED')
        AND b.updated_at < now() - interval '5 minutes'
    ),
    'dispatch_stats', jsonb_build_object(
      'avg_attempts_to_accept', (
        SELECT ROUND(AVG(b.dispatch_sequence),1)
        FROM bookings b
        WHERE b.status = 'CONFIRMED'
          AND b.created_at > now() - interval '7 days'
      ),
      'acceptance_rate_today', (
        SELECT ROUND(
          COUNT(*) FILTER (WHERE status = 'CONFIRMED')::NUMERIC /
          NULLIF(COUNT(*),0) * 100, 1
        )
        FROM bookings WHERE created_at > now() - interval '24 hours'
      )
    )
  );
END;
$$;

-- ── Admin: mark job priority (halves dispatch timeout) ────────
CREATE OR REPLACE FUNCTION admin_set_priority(
  p_admin_id   UUID,
  p_booking_id UUID,
  p_priority   BOOLEAN DEFAULT true,
  p_note       TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin BOOLEAN;
BEGIN
  SELECT user_role = 'admin' INTO v_is_admin FROM profiles WHERE id = p_admin_id;
  IF NOT v_is_admin THEN RETURN jsonb_build_object('error','Admin access required'); END IF;

  UPDATE bookings SET
    priority_flag = p_priority,
    admin_note    = COALESCE(p_note, admin_note),
    updated_at    = now()
  WHERE id = p_booking_id;

  INSERT INTO admin_overrides (booking_id, admin_id, action, payload, note)
  VALUES (p_booking_id, p_admin_id, 'set_priority',
    jsonb_build_object('priority', p_priority), p_note);

  RETURN jsonb_build_object('success', true, 'booking_id', p_booking_id, 'priority', p_priority);
END;
$$;

-- ── Auto-alert: notify admin when dispatch times out ──────────
-- Called inside advance_expired_dispatches when action = fallback
-- (already implemented there — this ensures admins get notified
--  even if cron hasn't run by checking on booking fetch)

CREATE OR REPLACE FUNCTION check_and_alert_stuck_jobs()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
BEGIN
  -- Alert admins for jobs stuck > 3 minutes with no fixer
  INSERT INTO notifications (user_id, title, body, type, related_id)
  SELECT DISTINCT ON (p.id, b.id)
    p.id,
    '🚨 Stuck job — needs attention',
    'Job ' || LEFT(b.id::TEXT, 8) || ' (' || COALESCE(b.category,'General') || ' · ' ||
      b.service_tier || ') stuck for ' ||
      ROUND(EXTRACT(EPOCH FROM (now() - b.updated_at))/60) || ' min. Dispatch seq: ' ||
      b.dispatch_sequence || '.',
    'admin_alert',
    b.id
  FROM bookings b
  CROSS JOIN profiles p
  WHERE b.status IN ('SEARCHING','OFFERED')
    AND b.updated_at < now() - interval '3 minutes'
    AND p.user_role = 'admin'
    AND NOT EXISTS (
      SELECT 1 FROM notifications n
      WHERE n.user_id     = p.id
        AND n.related_id  = b.id
        AND n.type        = 'admin_alert'
        AND n.created_at  > now() - interval '5 minutes'  -- don't spam
    );

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- ── Cron: alert on stuck jobs every 3 minutes ─────────────────
-- SELECT cron.schedule('alert-stuck-jobs', '3 minutes', $$SELECT check_and_alert_stuck_jobs()$$);
-- SELECT cron.schedule('assign-badges', '1 hour', $$SELECT assign_fixer_badges()$$);

GRANT EXECUTE ON FUNCTION assign_fixer_badges(UUID)             TO service_role;
GRANT EXECUTE ON FUNCTION admin_set_priority(UUID,UUID,BOOLEAN,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION check_and_alert_stuck_jobs()          TO service_role;
GRANT EXECUTE ON FUNCTION admin_dashboard()                     TO authenticated;
