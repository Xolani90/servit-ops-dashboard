-- ═══════════════════════════════════════════════════════════════
-- SERVIT v6.0 — Admin Override System
-- Enables "fake Uber" manual operations:
--   • Assign fixer manually
--   • Force job status
--   • Resolve stuck jobs
--   • Override dispatch
-- ═══════════════════════════════════════════════════════════════

-- ── Admin: manually assign a fixer to a booking ──────────────
CREATE OR REPLACE FUNCTION admin_assign_fixer(
  p_admin_id  UUID,
  p_booking_id UUID,
  p_fixer_id  UUID,
  p_note      TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin   BOOLEAN;
  v_booking    bookings%ROWTYPE;
  v_fixer      fixers%ROWTYPE;
BEGIN
  SELECT user_role = 'admin' INTO v_is_admin FROM profiles WHERE id = p_admin_id;
  IF NOT v_is_admin THEN
    RETURN jsonb_build_object('error', 'Admin access required');
  END IF;

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Booking not found'); END IF;

  SELECT * INTO v_fixer FROM fixers WHERE id = p_fixer_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Fixer not found'); END IF;

  PERFORM set_config('app.allow_status_change', 'true', true);

  -- Cancel any pending offers
  UPDATE offers SET status = 'expired', updated_at = now()
  WHERE booking_id = p_booking_id AND status = 'pending';

  -- Assign fixer
  UPDATE bookings SET
    fixer_id         = p_fixer_id,
    status           = 'CONFIRMED',
    confirmed_at     = now(),
    dispatch_mode    = 'manual',
    admin_note       = p_note,
    updated_at       = now(),
    version          = version + 1
  WHERE id = p_booking_id;

  -- Mark fixer busy
  PERFORM mark_fixer_busy(p_fixer_id);

  -- Notify both parties
  INSERT INTO notifications (user_id, title, body, type, related_id)
  VALUES
    (v_booking.customer_id, '✅ Fixer assigned!',
     'A fixer has been assigned to your job. They will be in touch shortly.',
     'booking_update', p_booking_id),
    (v_fixer.user_id, '📋 Job assigned to you',
     'An admin has assigned you to a job. Please contact the customer.',
     'booking_update', p_booking_id);

  -- Audit
  INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata, created_by)
  VALUES (p_booking_id, 'admin_assign', v_booking.status, 'CONFIRMED',
    jsonb_build_object('fixer_id', p_fixer_id, 'admin_id', p_admin_id, 'note', p_note),
    p_admin_id);

  INSERT INTO admin_overrides (booking_id, admin_id, action, payload, note)
  VALUES (p_booking_id, p_admin_id, 'assign_fixer',
    jsonb_build_object('fixer_id', p_fixer_id), p_note);

  RETURN jsonb_build_object(
    'success',    true,
    'booking_id', p_booking_id,
    'fixer_id',   p_fixer_id,
    'status',     'CONFIRMED'
  );
END;
$$;

-- ── Admin: force job status (resolve stuck jobs) ──────────────
CREATE OR REPLACE FUNCTION admin_force_status(
  p_admin_id   UUID,
  p_booking_id UUID,
  p_new_status TEXT,
  p_note       TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin   BOOLEAN;
  v_booking    bookings%ROWTYPE;
  v_old_status booking_status_enum;
BEGIN
  SELECT user_role = 'admin' INTO v_is_admin FROM profiles WHERE id = p_admin_id;
  IF NOT v_is_admin THEN
    RETURN jsonb_build_object('error', 'Admin access required');
  END IF;

  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Booking not found'); END IF;

  v_old_status := v_booking.status;
  PERFORM set_config('app.allow_status_change', 'true', true);

  UPDATE bookings SET
    status     = p_new_status::booking_status_enum,
    admin_note = COALESCE(p_note, admin_note),
    updated_at = now(),
    version    = version + 1
  WHERE id = p_booking_id;

  -- If completing, release fixer
  IF p_new_status IN ('COMPLETED', 'CANCELLED') AND v_booking.fixer_id IS NOT NULL THEN
    PERFORM mark_fixer_available(v_booking.fixer_id);
  END IF;

  INSERT INTO booking_events (booking_id, event_type, old_status, new_status, metadata, created_by)
  VALUES (p_booking_id, 'admin_force_status', v_old_status, p_new_status::booking_status_enum,
    jsonb_build_object('admin_id', p_admin_id, 'note', p_note), p_admin_id);

  INSERT INTO admin_overrides (booking_id, admin_id, action, payload, note)
  VALUES (p_booking_id, p_admin_id, 'force_status',
    jsonb_build_object('old_status', v_old_status, 'new_status', p_new_status), p_note);

  RETURN jsonb_build_object(
    'success',    true,
    'booking_id', p_booking_id,
    'old_status', v_old_status,
    'new_status', p_new_status
  );
END;
$$;

-- ── Admin: get dashboard summary ──────────────────────────────
CREATE OR REPLACE FUNCTION admin_dashboard()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'bookings', jsonb_build_object(
      'searching',   (SELECT count(*) FROM bookings WHERE status = 'SEARCHING'),
      'offered',     (SELECT count(*) FROM bookings WHERE status = 'OFFERED'),
      'confirmed',   (SELECT count(*) FROM bookings WHERE status = 'CONFIRMED'),
      'in_progress', (SELECT count(*) FROM bookings WHERE status = 'IN_PROGRESS'),
      'stuck',       (SELECT count(*) FROM bookings
                      WHERE status IN ('SEARCHING','OFFERED')
                        AND created_at < now() - interval '10 minutes'),
      'today',       (SELECT count(*) FROM bookings WHERE created_at > now() - interval '24 hours')
    ),
    'fixers', jsonb_build_object(
      'online',  (SELECT count(*) FROM fixers WHERE fixer_status = 'online'),
      'busy',    (SELECT count(*) FROM fixers WHERE fixer_status = 'busy'),
      'offline', (SELECT count(*) FROM fixers WHERE fixer_status = 'offline')
    ),
    'revenue', jsonb_build_object(
      'today', (SELECT COALESCE(sum(platform_fee),0) FROM payouts
                WHERE created_at > now() - interval '24 hours'),
      'week',  (SELECT COALESCE(sum(platform_fee),0) FROM payouts
                WHERE created_at > now() - interval '7 days')
    ),
    'stuck_jobs', (
      SELECT jsonb_agg(jsonb_build_object(
        'id', b.id, 'status', b.status, 'created_at', b.created_at,
        'category', b.category, 'tier', b.service_tier,
        'minutes_stuck', EXTRACT(EPOCH FROM (now() - b.updated_at))/60
      ))
      FROM bookings b
      WHERE b.status IN ('SEARCHING','OFFERED')
        AND b.created_at < now() - interval '10 minutes'
    )
  ) INTO v_result;
  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_assign_fixer(UUID, UUID, UUID, TEXT)         TO authenticated;
GRANT EXECUTE ON FUNCTION admin_force_status(UUID, UUID, TEXT, TEXT)         TO authenticated;
GRANT EXECUTE ON FUNCTION admin_dashboard()                                  TO authenticated;
