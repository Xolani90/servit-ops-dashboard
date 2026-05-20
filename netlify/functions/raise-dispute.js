// ═══════════════════════════════════════════════════════════════
// raise-dispute — Customer/fixer raises a dispute
// POST /.netlify/functions/raise-dispute
//
// v8.3 fix: parse and forward dispute_type so ops can route
//   pay_discrepancy queries (Earnings tab) to the finance team
//   rather than the general dispute queue.  Also stopped passing
//   dispute_type: undefined to the RPC when omitted — Postgres
//   would receive the string "undefined" and fail the CHECK.
// ═══════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

const VALID_DISPUTE_TYPES = new Set(['quality', 'pay_discrepancy', 'no_show', 'other']);

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};


// BUG 5 FIX (v8.6): Rate limit constants
const RATE_LIMIT_ACTION   = 'raise_dispute';
const RATE_LIMIT_MAX      = 10;     // max calls
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

    const {
      booking_id,
      reason,
      evidence_url,
      dispute_type,   // v8.3: forwarded to DB so ops can route correctly
    } = JSON.parse(event.body || '{}');

    // Input length caps — DB columns are unbounded TEXT
    const safeReason = reason ? String(reason).slice(0, 2000) : reason;
    const safeEvidenceUrl = evidence_url ? String(evidence_url).slice(0, 500) : null;

    if (!booking_id || !reason) {
      return {
        statusCode: 400,
        headers: CORS_HEADERS,
        body: JSON.stringify({ error: 'Missing booking_id or reason' }),
      };
    }

    // Normalise dispute_type — never send an invalid value to the DB CHECK constraint
    const safeDisputeType = VALID_DISPUTE_TYPES.has(dispute_type) ? dispute_type : 'quality';

    const { data: result, error: disputeError } = await supabase.rpc('raise_dispute', {
      p_booking_id:   booking_id,
      p_user_id:      user.id,
      p_reason:       safeReason,
      p_evidence_url: safeEvidenceUrl,
      p_dispute_type: safeDisputeType,
    });

    if (disputeError) {
      console.error('raise_dispute RPC error:', disputeError.message);
      return {
        statusCode: 500,
        headers: CORS_HEADERS,
        body: JSON.stringify({ error: disputeError.message }),
      };
    }

    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify(result),
    };

  } catch (error) {
    console.error('Raise dispute handler error:', error);
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ error: error.message || 'Internal server error' }),
    };
  }
};