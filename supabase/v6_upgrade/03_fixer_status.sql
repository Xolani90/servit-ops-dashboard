-- ═══════════════════════════════════════════════════════════════
-- SERVIT v6.0 — Fixer Status Management
-- Replaces toggle_fixer_availability with fixer_status system
-- States: online → busy (on job) → online (job done) / offline
-- ═══════════════════════════════════════════════════════════════

-- ── Set fixer status (online/offline toggle by fixer) ─────────
DROP FUNCTION IF EXISTS set_fixer_status(UUID, fixer_status_enum);
CREATE OR REPLACE FUNCTION set_fixer_status(
  p_user_id UUID,
  p_status  fixer_status_enum  -- only 'online' or 'offline' from frontend
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fixer fixers%ROWTYPE;
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);

  SELECT * INTO v_fixer FROM fixers WHERE user_id = p_user_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Fixer not found');
  END IF;

  -- Can't go online/offline while busy (mid-job)
  IF v_fixer.fixer_status = 'busy' AND p_status = 'offline' THEN
    RETURN jsonb_build_object(
      'error', 'Cannot go offline while a job is in progress. Complete your current job first.'
    );
  END IF;

  UPDATE fixers SET
    fixer_status  = p_status,
    available     = (p_status = 'online'),  -- keep old column in sync
    last_seen_at  = now(),
    last_active_at = CASE WHEN p_status = 'online' THEN now() ELSE last_active_at END,
    updated_at    = now()
  WHERE user_id = p_user_id;

  RETURN jsonb_build_object(
    'success',      true,
    'fixer_status', p_status,
    'available',    (p_status = 'online')
  );
END;
$$;

-- ── Mark fixer busy when job accepted ─────────────────────────
DROP FUNCTION IF EXISTS mark_fixer_busy(UUID);
CREATE OR REPLACE FUNCTION mark_fixer_busy(p_fixer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);
  UPDATE fixers SET
    fixer_status = 'busy',
    available    = false,
    updated_at   = now()
  WHERE id = p_fixer_id;
END;
$$;

-- ── Mark fixer available again after job completes/cancels ────
DROP FUNCTION IF EXISTS mark_fixer_available(UUID);
CREATE OR REPLACE FUNCTION mark_fixer_available(p_fixer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM set_config('app.allow_status_change', 'true', true);
  UPDATE fixers SET
    fixer_status = 'online',
    available    = true,
    updated_at   = now()
  WHERE id = p_fixer_id
    AND fixer_status = 'busy';  -- only release if was busy (not if manually went offline)
END;
$$;

-- ── Admin: force fixer status override ───────────────────────
DROP FUNCTION IF EXISTS admin_set_fixer_status(UUID, UUID, fixer_status_enum, TEXT);
CREATE OR REPLACE FUNCTION admin_set_fixer_status(
  p_admin_id UUID,
  p_fixer_id UUID,
  p_status   fixer_status_enum,
  p_note     TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin BOOLEAN;
BEGIN
  SELECT user_role = 'admin' INTO v_is_admin
  FROM profiles WHERE id = p_admin_id;

  IF NOT v_is_admin THEN
    RETURN jsonb_build_object('error', 'Admin access required');
  END IF;

  PERFORM set_config('app.allow_status_change', 'true', true);

  UPDATE fixers SET
    fixer_status = p_status,
    available    = (p_status = 'online'),
    updated_at   = now()
  WHERE id = p_fixer_id;

  INSERT INTO admin_overrides (booking_id, admin_id, action, payload, note)
  SELECT
    (SELECT id FROM bookings WHERE fixer_id = p_fixer_id AND status IN ('CONFIRMED','EN_ROUTE','ARRIVED','IN_PROGRESS') LIMIT 1),
    p_admin_id,
    'force_fixer_status',
    jsonb_build_object('fixer_id', p_fixer_id, 'new_status', p_status),
    p_note
  WHERE EXISTS (SELECT 1 FROM fixers WHERE id = p_fixer_id);

  RETURN jsonb_build_object('success', true, 'fixer_id', p_fixer_id, 'status', p_status);
END;
$$;

GRANT EXECUTE ON FUNCTION set_fixer_status(UUID, fixer_status_enum)    TO authenticated;
GRANT EXECUTE ON FUNCTION mark_fixer_busy(UUID)                        TO service_role;
GRANT EXECUTE ON FUNCTION mark_fixer_available(UUID)                   TO service_role;
GRANT EXECUTE ON FUNCTION admin_set_fixer_status(UUID, UUID, fixer_status_enum, TEXT) TO authenticated;
