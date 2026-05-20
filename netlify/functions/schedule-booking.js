const { createClient } = require('@supabase/supabase-js');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

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

    const { booking_id, schedule_for } = JSON.parse(event.body || '{}');
    if (!booking_id || !schedule_for) {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Missing booking_id or schedule_for' }) };
    }

    const { data: booking, error: bkErr } = await supabase
      .from('bookings')
      .select('id, customer_id, status, payment_status')
      .eq('id', booking_id)
      .maybeSingle();
    if (bkErr || !booking) return { statusCode: 404, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Booking not found' }) };
    if (booking.customer_id !== user.id) return { statusCode: 403, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Forbidden' }) };
    if (!['SEARCHING', 'OFFERED'].includes(booking.status) || booking.payment_status !== 'paid') {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Booking cannot be rescheduled in current state' }) };
    }

    const scheduleTs = new Date(schedule_for);
    if (Number.isNaN(scheduleTs.getTime()) || scheduleTs.getTime() <= Date.now() + (15 * 60 * 1000)) {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'schedule_for must be at least 15 minutes in the future' }) };
    }

    const { error: resetError } = await supabase.rpc('reset_booking_to_searching', {
      p_booking_id: booking_id,
      p_actor_user_id: user.id,
      p_reason: 'customer_scheduled_retry',
      p_booking_mode: 'scheduled',
      p_scheduled_for: scheduleTs.toISOString(),
    });
    if (resetError) return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: resetError.message }) };

    await supabase.from('booking_events').insert({
      booking_id,
      event_type: 'customer_scheduled_retry',
      old_status: 'SEARCHING',
      new_status: 'SEARCHING',
      created_by: user.id,
      metadata: { scheduled_for: scheduleTs.toISOString() },
    });

    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ok: true, booking_id, scheduled_for: scheduleTs.toISOString() }),
    };
  } catch (error) {
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ error: error.message || 'Internal server error' }),
    };
  }
};
