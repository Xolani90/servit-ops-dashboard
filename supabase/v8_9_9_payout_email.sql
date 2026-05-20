-- ═══════════════════════════════════════════════════════════════════════════
-- SERVIT v8.9.9 — Payout Released Email to Fixer
-- Run AFTER v8_5_production.sql
-- Idempotent — safe to re-run.
--
-- PURPOSE:
--   When a payout is released, send an email to the fixer confirming the amount,
--   the job it relates to, and an estimated arrival time of 1-3 business days.
--
-- CHANGES:
--   - Modified release_due_payouts_v2 to return released payout details
--     (fixer_email, net_amount, booking_id, service_amount) in a JSONB array
--   - This allows the Netlify function release-payouts.js to send emails
-- ═══════════════════════════════════════════════════════════════════════════

-- Update release_due_payouts_v2 to return released payout details for email sending
CREATE OR REPLACE FUNCTION release_due_payouts_v2(
  p_trigger TEXT DEFAULT 'pg_cron'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_run_id      UUID;
  v_rec         RECORD;
  v_total       INTEGER := 0;
  v_amount      NUMERIC(12,2) := 0;
  v_err_msg     TEXT := NULL;
  v_released    JSONB := '[]'::jsonb;
BEGIN
  -- Start audit row
  INSERT INTO payout_runs (trigger) VALUES (p_trigger) RETURNING id INTO v_run_id;

  BEGIN
    FOR v_rec IN
      SELECT p.id AS payout_id, p.fixer_id, p.net_amount, p.booking_id,
             pr.email AS fixer_email, b.service_amount
      FROM   payouts p
      JOIN   bookings b ON b.id = p.booking_id
      JOIN   fixers f ON f.id = p.fixer_id
      JOIN   profiles pr ON pr.id = f.user_id
      WHERE  p.status    = 'held'
        AND  p.hold_until <= now()
        AND  b.status   != 'DISPUTED'
      FOR UPDATE OF p SKIP LOCKED
    LOOP
      UPDATE payouts SET
        status      = 'released',
        released_at = now(),
        updated_at  = now()
      WHERE id = v_rec.payout_id;

      -- Update fixer total_earnings running total
      PERFORM set_config('app.allow_status_change', 'true', true);
      UPDATE fixers SET
        total_earnings = COALESCE(total_earnings, 0) + v_rec.net_amount,
        updated_at     = now()
      WHERE id = v_rec.fixer_id;

      INSERT INTO notifications (user_id, title, body, type, related_id)
      SELECT
        f.user_id,
        '✅ Payment released',
        'Your payment of R' || v_rec.net_amount::TEXT || ' has been released. Check your bank account within 1-2 business days.',
        'payout_released',
        v_rec.booking_id
      FROM fixers f WHERE f.id = v_rec.fixer_id;

      v_total  := v_total + 1;
      v_amount := v_amount + v_rec.net_amount;

      -- Collect released payout details for email sending
      v_released := v_released || jsonb_build_object(
        'fixer_id', v_rec.fixer_id,
        'fixer_email', v_rec.fixer_email,
        'net_amount', v_rec.net_amount,
        'booking_id', v_rec.booking_id,
        'service_amount', v_rec.service_amount
      );
    END LOOP;

  EXCEPTION WHEN OTHERS THEN
    v_err_msg := SQLERRM;
  END;

  -- Close audit row
  UPDATE payout_runs SET
    finished_at      = now(),
    payouts_released = v_total,
    total_amount     = v_amount,
    error_msg        = v_err_msg
  WHERE id = v_run_id;

  IF v_err_msg IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', v_err_msg, 'released', v_total, 'run_id', v_run_id);
  END IF;

  RETURN jsonb_build_object('ok', true, 'released', v_total, 'total_amount', v_amount, 'run_id', v_run_id, 'released_payouts', v_released);
END;
$$;

GRANT EXECUTE ON FUNCTION release_due_payouts_v2(TEXT) TO service_role;
