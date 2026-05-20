// ═══════════════════════════════════════════════════════════════
// toggle-availability — Securely flip fixer availability
// POST /api/toggle-availability
//
// FIX (Audit Failure 1): The frontend was calling supabaseClient
// .from('fixers').update({ available }) directly with the anon key,
// bypassing all security. No RLS existed on the available column.
// Any authenticated user could take any fixer offline.
//
// This function:
//   1. Authenticates the caller via JWT
//   2. Resolves their fixer record (ownership check — user_id must match)
//   3. Guards against going online while a job is active
//   4. Atomically flips the available flag via toggle_fixer_availability()
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
const RATE_LIMIT_ACTION   = 'toggle_availability';
const RATE_LIMIT_MAX      = 60;     // max calls
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

    // Ownership check — only fetch the fixer row that belongs to this user
    const { data: fixer, error: fixerError } = await supabase
      .from('fixers')
      .select('id, available, status')
      .eq('user_id', user.id)
      .eq('status', 'approved')
      .maybeSingle();

    if (fixerError || !fixer) {
      return {
        statusCode: 403,
        headers: CORS_HEADERS,
        body: JSON.stringify({ error: 'No approved fixer profile found for this user' }),
      };
    }

    // Delegate to DB function which enforces the active-job guard atomically
    const { data: result, error: toggleError } = await supabase.rpc(
      'toggle_fixer_availability',
      { p_fixer_id: fixer.id, p_user_id: user.id }
    );

    if (toggleError) {
      // Surface the DB-level error message (e.g. "Cannot go online while a job is active")
      return {
        statusCode: 400,
        headers: CORS_HEADERS,
        body: JSON.stringify({ error: toggleError.message }),
      };
    }

    // FIX D: When a fixer goes online, immediately stamp last_seen_at.
    // match_fixers() requires last_seen_at >= now() - interval '8 minutes'.
    // toggle_fixer_availability() only flips the available flag — without this
    // stamp, a fixer who just toggled online but hasn't sent a heartbeat yet
    // has a stale last_seen_at and is invisible to matching until the next
    // 60-second heartbeat fires. This makes them eligible from the moment
    // they tap "Go Online".
    if (result?.available === true) {
      await supabase
        .from('fixers')
        .update({ last_seen_at: new Date().toISOString() })
        .eq('id', fixer.id)
        .then(({ error: lsErr }) => {
          if (lsErr) console.warn('[toggle-availability] last_seen_at stamp failed (non-fatal):', lsErr.message);
        });
    }

    return {
      statusCode: 200,
      headers: { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' },
      body: JSON.stringify(result),
    };

  } catch (error) {
    console.error('toggle-availability error:', error);
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ error: error.message || 'Internal server error' }),
    };
  }
};
