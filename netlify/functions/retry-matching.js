const { createClient } = require('@supabase/supabase-js');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

const BASE_RADIUS_KM = 25;
const STEP_RADIUS_KM = 15;
const MAX_RADIUS_KM = 85;

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: CORS_HEADERS };
  if (event.httpMethod !== 'POST') return { statusCode: 405, headers: CORS_HEADERS, body: 'Method Not Allowed' };

  try {
    const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_KEY, { auth: { persistSession: false } });
    const authHeader = event.headers.authorization;
    if (!authHeader) return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Unauthorized' }) };

    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    if (userError || !user) return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Invalid token' }) };

    const { booking_id } = JSON.parse(event.body || '{}');
    if (!booking_id) return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Missing booking_id' }) };

    const { data: booking, error: bkErr } = await supabase
      .from('bookings')
      .select('id, customer_id, status, payment_status')
      .eq('id', booking_id)
      .maybeSingle();
    if (bkErr || !booking) return { statusCode: 404, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Booking not found' }) };
    if (booking.customer_id !== user.id) return { statusCode: 403, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Forbidden' }) };
    if (!['SEARCHING', 'OFFERED'].includes(booking.status) || booking.payment_status !== 'paid') {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Booking is not eligible for retry matching' }) };
    }

    const { count: retryCount } = await supabase
      .from('booking_events')
      .select('id', { count: 'exact', head: true })
      .eq('booking_id', booking_id)
      .eq('event_type', 'manual_retry_search');

    const radiusKm = Math.min(MAX_RADIUS_KM, BASE_RADIUS_KM + ((retryCount || 0) * STEP_RADIUS_KM));

    const { error: resetError } = await supabase.rpc('reset_booking_to_searching', {
      p_booking_id: booking_id,
      p_actor_user_id: user.id,
      p_reason: 'manual_retry_expand_radius',
    });
    if (resetError) return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: resetError.message }) };

    await supabase.from('booking_events').insert({
      booking_id,
      event_type: 'manual_retry_search',
      old_status: 'SEARCHING',
      new_status: 'SEARCHING',
      created_by: user.id,
      metadata: { radius_km: radiusKm },
    });

    const { data: requestRes, error: requestErr } = await supabase.rpc('request_matching', {
      p_booking_id: booking_id,
      p_requested_by: 'cron',
      p_priority: 5, // Medium priority for cron retry
      p_radius_km: radiusKm,
      p_batch_size: 4,
      p_metadata: { source: 'retry-matching-cron' }
    });

    if (requestErr) return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: requestErr.message }) };
    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        ok: true,
        booking_id,
        radius_km: radiusKm,
        request_id: requestRes,
        message: 'Matching request queued',
      }),
    };
  } catch (error) {
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ error: error.message || 'Internal server error' }),
    };
  }
};
