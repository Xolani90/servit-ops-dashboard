-- ═══════════════════════════════════════════════════════════════
-- SERVIT v5.2 — Database Triggers
-- Changes from v5.1:
--   FIX 8: log_booking_status trigger REMOVED — it created duplicate
--           booking_events rows (one from trigger, one from each DB
--           function's explicit INSERT). Canonical audit log is the
--           explicit INSERT inside each SECURITY DEFINER function.
-- ═══════════════════════════════════════════════════════════════

-- ── Auto-create profile on auth.user creation ────────────────
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, email, user_role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'user_role', 'customer')
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ── Auto-create fixer record when user signs up as fixer ─────
CREATE OR REPLACE FUNCTION handle_new_fixer_user()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.raw_user_meta_data->>'user_role' = 'fixer' THEN
    INSERT INTO public.fixers (user_id, full_name, city, status)
    VALUES (
      NEW.id,
      COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)),
      COALESCE(NEW.raw_user_meta_data->>'city', ''),
      'pending'
    );
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_fixer ON auth.users;
CREATE TRIGGER on_auth_user_fixer
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_fixer_user();

-- ═══════════════════════════════════════════════════════════════
-- GUARD: Prevent direct booking status changes from the frontend.
--
-- Every DB function that legitimately changes booking status must
-- call: PERFORM set_config('app.allow_status_change', 'true', true);
-- at the top of its transaction. Frontend REST calls cannot set
-- this variable.
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION prevent_direct_booking_update()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF current_setting('app.allow_status_change', true) IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION
        'Direct booking status changes are forbidden. Use the server-side functions.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS prevent_booking_status_update ON bookings;
CREATE TRIGGER prevent_booking_status_update
  BEFORE UPDATE ON bookings
  FOR EACH ROW
  EXECUTE FUNCTION prevent_direct_booking_update();

-- FIX 8: log_booking_status trigger intentionally NOT recreated.
-- Every status-changing DB function (update_job_status, accept_offer,
-- expire_offers, resolve_dispute, match_fixers) inserts its own
-- booking_events row with richer metadata (offer_id, fixer_id, etc.).
-- The trigger was creating a second duplicate row on every transition.
-- Ensure the trigger is dropped if this runs against an existing DB:
DROP TRIGGER IF EXISTS log_booking_status ON bookings;
DROP FUNCTION IF EXISTS log_booking_status_change();

-- ═══════════════════════════════════════════════════════════════
-- GUARD: Prevent fixers from self-approving their status.
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION prevent_fixer_self_approval()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF current_setting('app.allow_status_change', true) IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION
        'Fixer status changes require admin approval. Direct status updates are forbidden.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS prevent_fixer_status_update ON fixers;
CREATE TRIGGER prevent_fixer_status_update
  BEFORE UPDATE ON fixers
  FOR EACH ROW
  EXECUTE FUNCTION prevent_fixer_self_approval();

-- ═══════════════════════════════════════════════════════════════
-- GUARD: Prevent direct REST writes to fixers.available.
-- Only toggle_fixer_availability() and update_job_status() may
-- change this column (they set app.allow_status_change first).
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION prevent_direct_available_update()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.available IS DISTINCT FROM OLD.available THEN
    IF current_setting('app.allow_status_change', true) IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION
        'Direct update to fixers.available is not permitted. Use the toggle-availability API.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$
LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS prevent_direct_fixer_available_update ON fixers;
CREATE TRIGGER prevent_direct_fixer_available_update
  BEFORE UPDATE ON fixers
  FOR EACH ROW
  EXECUTE FUNCTION prevent_direct_available_update();

-- ═══════════════════════════════════════════════════════════════
-- Enable Realtime on tables the frontend subscribes to
-- ═══════════════════════════════════════════════════════════════

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bookings', 'offers', 'notifications', 'reviews', 'payouts']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE %I', t);
    END IF;
  END LOOP;
END $$;
