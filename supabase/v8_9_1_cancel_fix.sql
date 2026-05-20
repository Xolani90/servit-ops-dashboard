-- ═══════════════════════════════════════════════════════════════
-- v8.9.1 — Fix: CREATED → CANCELLED missing from state machine
--
-- ROOT CAUSE of cancel-booking 400 (Bad Request):
--   When a customer abandons a Yoco payment (paymentStatus='cancelled')
--   the frontend calls cancel-booking to clean up the orphan booking.
--   That booking is still in CREATED state (never advanced to
--   PENDING_PAYMENT because Yoco redirected before payment).
--   validate_booking_transition() returned FALSE for CREATED→CANCELLED,
--   causing update_job_status() to RAISE EXCEPTION "Invalid status
--   transition", which cancel-booking caught and returned as a 400.
--
-- FIX: Add CREATED→CANCELLED to the allowed transition table.
--   This is safe — the customer owns their CREATED booking and
--   no money has been taken at this point.
--
-- ALSO included in this patch: SEARCHING→EXPIRED was already added
-- in v8.7 but we keep it here for completeness in case this is run
-- on a DB that only has the base schema.sql applied.
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION validate_booking_transition(
  old_status booking_status_enum,
  new_status booking_status_enum
)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN (
    -- Normal forward flow
    (old_status = 'CREATED'             AND new_status = 'PENDING_PAYMENT') OR
    (old_status = 'PENDING_PAYMENT'     AND new_status = 'SEARCHING') OR
    (old_status = 'SEARCHING'           AND new_status = 'OFFERED') OR
    (old_status = 'SEARCHING'           AND new_status = 'EXPIRED') OR     -- search timeout
    (old_status = 'OFFERED'             AND new_status = 'CONFIRMED') OR
    (old_status = 'OFFERED'             AND new_status = 'SEARCHING') OR   -- decline / expire
    (old_status = 'CONFIRMED'           AND new_status = 'EN_ROUTE') OR
    (old_status = 'EN_ROUTE'            AND new_status = 'ARRIVED') OR
    (old_status = 'ARRIVED'             AND new_status = 'IN_PROGRESS') OR
    (old_status = 'IN_PROGRESS'         AND new_status = 'PENDING_COMPLETION') OR
    (old_status = 'PENDING_COMPLETION'  AND new_status = 'COMPLETED') OR

    -- Dispute paths
    (old_status = 'CONFIRMED'           AND new_status = 'DISPUTED') OR
    (old_status = 'IN_PROGRESS'         AND new_status = 'DISPUTED') OR
    (old_status = 'PENDING_COMPLETION'  AND new_status = 'DISPUTED') OR
    -- resolve_dispute() outcomes
    (old_status = 'DISPUTED'            AND new_status = 'COMPLETED') OR
    (old_status = 'DISPUTED'            AND new_status = 'CANCELLED') OR

    -- Cancellation paths
    (old_status = 'CREATED'             AND new_status = 'CANCELLED') OR   -- ← FIX: orphan cleanup
    (old_status = 'PENDING_PAYMENT'     AND new_status = 'CANCELLED') OR
    (old_status = 'PENDING_PAYMENT'     AND new_status = 'EXPIRED') OR
    (old_status = 'SEARCHING'           AND new_status = 'CANCELLED') OR
    (old_status = 'OFFERED'             AND new_status = 'CANCELLED') OR
    (old_status = 'OFFERED'             AND new_status = 'EXPIRED') OR
    (old_status = 'CONFIRMED'           AND new_status = 'CANCELLED') OR
    (old_status = 'EN_ROUTE'            AND new_status = 'CANCELLED') OR   -- fixer abort
    (old_status = 'ARRIVED'             AND new_status = 'CANCELLED')
  );
END;
$$;
