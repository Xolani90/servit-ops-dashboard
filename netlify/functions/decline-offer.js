// ═══════════════════════════════════════════════════════════════
// decline-offer — Fixer declines a job offer, triggers rematch
// POST /.netlify/functions/decline-offer
// ═══════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};


// BUG 5 FIX (v8.6): Rate limit constants
const RATE_LIMIT_ACTION   = 'decline_offer';
const RATE_LIMIT_MAX      = 30;     // max calls
const RATE_LIMIT_WINDOW   = 3600;   // per hour (seconds)

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 204, headers: CORS_HEADERS };
  }

  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers: CORS_HEADERS, body: 'Method Not Allowed' };
  }

  try {
    const authHeader = event.headers.authorization;
    if (!authHeader) {
      return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Unauthorized' }) };
    }

    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    if (userError || !user) {
      return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Invalid token' }) };
    }

    // ── BUG 5 FIX: Rate limit check ─────────────────────────────
    const { data: allowed, error: rlError } = await supabase.rpc('check_rate_limit', {
      p_user_id:        user.id,
      p_action:         RATE_LIMIT_ACTION,
      p_max_calls:      RATE_LIMIT_MAX,
      p_window_seconds: RATE_LIMIT_WINDOW,
    });
    if (rlError) {
      console.error('Rate limit check error:', rlError.message);
      // Fail open — do not block legitimate traffic on a rate-limit DB error
    } else if (!allowed) {
      return {
        statusCode: 429,
        headers: { ...CORS_HEADERS, 'Retry-After': '3600' },
        body: JSON.stringify({ error: 'Rate limit exceeded. Try again later.' }),
      };
    }

    const { offer_id, decline_reason } = JSON.parse(event.body || '{}');

    if (!offer_id) {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Missing offer_id' }) };
    }

    const { data: fixer, error: fixerError } = await supabase
      .from('fixers')
      .select('id')
      .eq('user_id', user.id)
      .maybeSingle();

    if (fixerError || !fixer) {
      return { statusCode: 403, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Not a registered fixer' }) };
    }

    const { data: result, error: declineError } = await supabase.rpc('decline_offer', {
      p_offer_id:      offer_id,
      p_fixer_id:      fixer.id,
      p_fixer_user_id: user.id,
      // FIX 5: Forward the decline reason captured in the UI to the DB for
      // supply-side analytics. Previously this field was sent by the frontend
      // but dropped here — the DB column was always NULL, losing the insight.
      ...(decline_reason ? { p_decline_reason: decline_reason } : {}),
    });

    if (declineError) {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: declineError.message }) };
    }

    // After decline, signal matching request for zero-latency retry.
    if (result.booking_id) {
      supabase.rpc('request_matching', {
        p_booking_id: result.booking_id,
        p_requested_by: 'decline',
        p_priority: 8, // High priority for decline retry
        p_radius_km: 25.0,
        p_batch_size: 3,
        p_metadata: { source: 'decline-offer' }
      })
        .then(({ error }) => { if (error) console.error('Matching request error after decline:', error.message); });
    }

    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify(result),
    };

  } catch (error) {
    console.error('Decline offer error:', error);
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ error: error.message || 'Internal server error' }),
    };
  }
};
