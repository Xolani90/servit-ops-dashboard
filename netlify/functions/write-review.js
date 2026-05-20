// ═══════════════════════════════════════════════════════════════
// write-review — Customer submits a rating + comment after COMPLETED job
// POST /.netlify/functions/write-review
// Body: { booking_id, rating (1-5), comment? }
// ═══════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

const CORS = {
  'Access-Control-Allow-Origin': process.env.URL || '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};


// BUG 5 FIX (v8.6): Rate limit constants
const RATE_LIMIT_ACTION   = 'write_review';
const RATE_LIMIT_MAX      = 20;     // max calls
const RATE_LIMIT_WINDOW   = 3600;   // per hour (seconds)

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: CORS };
  if (event.httpMethod !== 'POST') return { statusCode: 405, headers: CORS, body: 'Method Not Allowed' };

  try {
    const token = (event.headers.authorization || '').replace('Bearer ', '');
    if (!token) return { statusCode: 401, headers: CORS, body: JSON.stringify({ error: 'Unauthorized' }) };

    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    if (userError || !user) return { statusCode: 401, headers: CORS, body: JSON.stringify({ error: 'Invalid token' }) };

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
        headers: { ...CORS, 'Retry-After': '3600' },
        body: JSON.stringify({ error: 'Rate limit exceeded. Try again later.' }),
      };
    }

    const { booking_id, rating, comment } = JSON.parse(event.body || '{}');

    // Input length cap
    const safeComment = comment ? String(comment).slice(0, 2000) : null;
    // Coerce to integer — string "abc" produces NaN which bypasses < 1 and > 5 checks
    const safeRating = parseInt(rating, 10);

    if (!booking_id) return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: 'Missing booking_id' }) };
    if (!safeRating || safeRating < 1 || safeRating > 5) return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: 'Rating must be 1–5' }) };

    const { data: result, error } = await supabase.rpc('write_review', {
      p_booking_id:  booking_id,
      p_reviewer_id: user.id,
      p_rating:      safeRating,
      p_comment:     safeComment,
    });

    if (error) return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: error.message }) };

    return {
      statusCode: 200,
      headers: { ...CORS, 'Content-Type': 'application/json' },
      body: JSON.stringify(result),
    };
  } catch (err) {
    console.error('write-review error:', err);
    return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: err.message }) };
  }
};
