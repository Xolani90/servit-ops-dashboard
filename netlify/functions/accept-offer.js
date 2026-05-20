// ═══════════════════════════════════════════════════════════════
// accept-offer — Fixer accepts a job offer
// POST /.netlify/functions/accept-offer
//
// BUG 5 FIX: Added DB-side rate limiting (20 accepts / hour per user).
// Uses check_rate_limit() RPC added in v8_6_bugfixes.sql.
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

// BUG 5 FIX: Rate limit constants
const RATE_LIMIT_ACTION   = 'accept_offer';
const RATE_LIMIT_MAX      = 20;     // max calls
const RATE_LIMIT_WINDOW   = 3600;   // per hour (seconds)

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 204, headers: CORS_HEADERS };
  }
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers: CORS_HEADERS, body: 'Method Not Allowed' };
  }

  try {
    // ── Auth ────────────────────────────────────────────────────
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

    // ── Input validation ────────────────────────────────────────
    const { offer_id } = JSON.parse(event.body || '{}');
    if (!offer_id) {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Missing offer_id' }) };
    }

    // ── Verify caller is an approved fixer ──────────────────────
    const { data: fixer, error: fixerError } = await supabase
      .from('fixers')
      .select('id')
      .eq('user_id', user.id)
      .eq('status', 'approved')
      .maybeSingle();

    if (fixerError || !fixer) {
      return { statusCode: 403, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Not a registered fixer' }) };
    }

    // ── Delegate to DB RPC ──────────────────────────────────────
    const { data: result, error: acceptError } = await supabase.rpc('accept_offer', {
      p_offer_id:     offer_id,
      p_fixer_id:     fixer.id,
      p_fixer_user_id: user.id,
    });

    if (acceptError) {
      console.error('Accept offer error:', acceptError);
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: acceptError.message }) };
    }

    // ── Push notification (fire-and-forget) ─────────────────────
    if (result?.booking_id) {
      const { data: booking } = await supabase
        .from('bookings')
        .select('customer_id, description')
        .eq('id', result.booking_id)
        .maybeSingle();

      if (booking?.customer_id) {
        const internalSecret = process.env.INTERNAL_SECRET;
        const appUrl = process.env.APP_URL || process.env.URL;
        if (!internalSecret) {
          console.error('[FATAL CONFIG] INTERNAL_SECRET is not set — skipping customer acceptance push.');
        } else if (!appUrl) {
          console.error('[FATAL CONFIG] Neither APP_URL nor URL is set — skipping customer acceptance push.');
        } else {
          fetch(`${appUrl}/.netlify/functions/send-push`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-Internal-Secret': internalSecret },
            body: JSON.stringify({
              userId: booking.customer_id,
              title:  '✅ Fixer Accepted!',
              body:   `Your fixer is confirmed for "${(booking.description || 'job').substring(0, 50)}"`,
              data:   { type: 'booking', bookingId: result.booking_id },
            }),
          }).catch(e => console.error('Push notification error:', e));
        }
      }
    }

    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify(result),
    };

  } catch (error) {
    console.error('Accept offer handler error:', error);
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ error: error.message || 'Internal server error' }),
    };
  }
};