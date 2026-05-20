-- ═══════════════════════════════════════════════════════════════
-- SERVIT v8.9.5 — Match Fixers Consolidation
-- 
-- Consolidates all match_fixers() call sites into a single authoritative
-- pathway using a signal-then-match pattern. All pathways now signal intent
-- via matching_requests table, and one worker processes requests.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Create matching_requests table ─────────────────────────────
CREATE TABLE IF NOT EXISTS matching_requests (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  booking_id UUID NOT NULL REFERENCES bookings(id) ON DELETE CASCADE,
  requested_by TEXT NOT NULL, -- 'webhook', 'verify-payment', 'cron', 'decline', 'reconcile'
  priority INTEGER DEFAULT 0, -- Higher priority = process first
  radius_km DOUBLE PRECISION DEFAULT 25.0,
  batch_size INTEGER DEFAULT 3,
  metadata JSONB DEFAULT '{}'::jsonb,
  processed BOOLEAN DEFAULT false,
  processed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT unprocessed_booking UNIQUE (booking_id, processed)
);

-- Index for efficient querying
CREATE INDEX idx_matching_requests_processed ON matching_requests(processed, priority DESC, created_at ASC);
CREATE INDEX idx_matching_requests_booking_id ON matching_requests(booking_id);

-- ── 2. Create request_matching() function ─────────────────────────
CREATE OR REPLACE FUNCTION request_matching(
  p_booking_id UUID,
  p_requested_by TEXT,
  p_priority INTEGER DEFAULT 0,
  p_radius_km DOUBLE PRECISION DEFAULT 25.0,
  p_batch_size INTEGER DEFAULT 3,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request_id UUID;
  v_existing_priority INTEGER;
BEGIN
  -- Check if there's already an unprocessed request
  SELECT priority INTO v_existing_priority
  FROM matching_requests
  WHERE booking_id = p_booking_id AND processed = false;

  IF v_existing_priority IS NOT NULL THEN
    -- Update existing request with higher priority if needed
    UPDATE matching_requests
    SET 
      priority = GREATEST(matching_requests.priority, p_priority),
      radius_km = GREATEST(matching_requests.radius_km, p_radius_km),
      batch_size = GREATEST(matching_requests.batch_size, p_batch_size),
      metadata = matching_requests.metadata || p_metadata,
      created_at = CASE 
        WHEN p_priority > matching_requests.priority THEN now()
        ELSE matching_requests.created_at
      END
    WHERE booking_id = p_booking_id AND processed = false
    RETURNING id INTO v_request_id;
  ELSE
    -- Insert new request
    INSERT INTO matching_requests (
      booking_id, requested_by, priority, radius_km, batch_size, metadata
    ) VALUES (
      p_booking_id, p_requested_by, p_priority, p_radius_km, p_batch_size, p_metadata
    )
    RETURNING id INTO v_request_id;
  END IF;

  RETURN v_request_id;
END;
$$;

-- ── 3. Create process_matching_requests() worker ─────────────────
CREATE OR REPLACE FUNCTION process_matching_requests()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request RECORD;
  v_processed_count INTEGER := 0;
  v_skipped_count INTEGER := 0;
  v_error_count INTEGER := 0;
  v_match_result JSONB;
BEGIN
  -- Process highest priority unprocessed requests (batch of 10)
  FOR v_request IN
    SELECT *
    FROM matching_requests
    WHERE processed = false
    ORDER BY priority DESC, created_at ASC
    LIMIT 10
    FOR UPDATE
  LOOP
    BEGIN
      -- Check if booking is still eligible for matching
      IF EXISTS (
        SELECT 1 FROM bookings 
        WHERE id = v_request.booking_id 
          AND status = 'SEARCHING' 
          AND payment_status = 'paid'
      ) THEN
        -- Call match_fixers with request parameters
        SELECT match_fixers(
          v_request.booking_id,
          v_request.radius_km,
          v_request.batch_size
        ) INTO v_match_result;

        -- Mark as processed
        UPDATE matching_requests
        SET processed = true,
            processed_at = now()
        WHERE id = v_request.id;

        v_processed_count := v_processed_count + 1;
      ELSE
        -- Booking no longer eligible, skip
        UPDATE matching_requests
        SET processed = true,
            processed_at = now(),
            metadata = metadata || jsonb_build_object('skip_reason', 'booking_not_eligible')
        WHERE id = v_request.id;

        v_skipped_count := v_skipped_count + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- Log error but continue processing other requests
      UPDATE matching_requests
      SET processed = true,
          processed_at = now(),
          metadata = metadata || jsonb_build_object('error', SQLERRM)
      WHERE id = v_request.id;

      v_error_count := v_error_count + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', v_processed_count,
    'skipped', v_skipped_count,
    'errors', v_error_count
  );
END;
$$;

-- ── 4. Add scheduled worker cron job ───────────────────────────────
-- Run every 5 seconds to process matching requests
SELECT cron.schedule(
  'process-matching-requests',
  '*/5 * * * *',
  $$ SELECT process_matching_requests(); $$
);

-- ── 5. Migration tracking ─────────────────────────────────────────
INSERT INTO schema_migrations (version) VALUES ('v8.9.5') ON CONFLICT DO NOTHING;
