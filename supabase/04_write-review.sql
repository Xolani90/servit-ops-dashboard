-- ═══════════════════════════════════════════════════════════════
-- write_review — fixed for actual schema (fixers, not pro_profiles)
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION write_review(
  p_booking_id  UUID,
  p_reviewer_id UUID,
  p_rating      INTEGER,
  p_comment     TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_booking   bookings%ROWTYPE;
  v_fixer     fixers%ROWTYPE;
  v_review_id UUID;
BEGIN
  SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found';
  END IF;

  -- Only the customer can review
  IF v_booking.customer_id != p_reviewer_id THEN
    RAISE EXCEPTION 'Only the customer can leave a review';
  END IF;

  -- Booking must be completed
  IF v_booking.status != 'COMPLETED' THEN
    RAISE EXCEPTION 'Can only review COMPLETED bookings (current: %)', v_booking.status;
  END IF;

  IF v_booking.fixer_id IS NULL THEN
    RAISE EXCEPTION 'Booking has no fixer assigned';
  END IF;

  IF p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'Rating must be between 1 and 5';
  END IF;

  SELECT * INTO v_fixer FROM fixers WHERE id = v_booking.fixer_id;

  INSERT INTO reviews (booking_id, reviewer_id, reviewee_id, fixer_id, rating, comment)
  VALUES (p_booking_id, p_reviewer_id, v_fixer.user_id, v_fixer.id, p_rating, p_comment)
  RETURNING id INTO v_review_id;

  -- Recompute rolling average on fixers
  UPDATE fixers SET
    rating       = (SELECT ROUND(AVG(rating)::numeric, 2) FROM reviews WHERE fixer_id = v_fixer.id),
    review_count = (SELECT COUNT(*) FROM reviews WHERE fixer_id = v_fixer.id),
    updated_at   = now()
  WHERE id = v_fixer.id;

  -- Audit
  INSERT INTO booking_events (booking_id, event_type, metadata, created_by)
  VALUES (
    p_booking_id,
    'review_submitted',
    jsonb_build_object('review_id', v_review_id, 'rating', p_rating),
    p_reviewer_id
  );

  RETURN jsonb_build_object(
    'success',   true,
    'review_id', v_review_id,
    'fixer_id',  v_fixer.id,
    'rating',    p_rating
  );
END;
$$;
