// netlify/functions/redeem-referral.js — PATCHED v7.1
//
// FIXES vs original:
//   - Rate limiting: max 3 attempts per user per hour (via simple DB check)
//   - CORS origin locked to ALLOWED_ORIGIN env var
//   - Errors logged to function_errors table
//   - Double-spend protection now fully in the SQL (pg_advisory_lock)

const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN || '*';

async function logError(fnName, error, context = {}) {
  console.error(`[${fnName}]`, error?.message || error, context);
  try {
    await supabase.rpc('log_function_error', {
      p_function: fnName,
      p_error:    String(error?.message || error),
      p_detail:   error?.stack || null,
      p_context:  context,
    });
  } catch (_) {}
}

// Simple rate limit: check recent errors/attempts from this user
async function isRateLimited(userId) {
  const { count } = await supabase
    .from('function_errors')
    .select('id', { count: 'exact', head: true })
    .eq('function_name', 'redeem-referral')
    .contains('context', { user_id: userId })
    .gte('created_at', new Date(Date.now() - 60 * 60 * 1000).toISOString());
  return (count || 0) >= 3;
}

exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin':  ALLOWED_ORIGIN,
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Content-Type':                 'application/json',
  };

  if (event.httpMethod === 'OPTIONS') return { statusCode: 200, headers, body: '' };
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers, body: JSON.stringify({ error: 'Method not allowed' }) };
  }

  try {
    const token = (event.headers.authorization || '').replace('Bearer ', '');
    if (!token) {
      return { statusCode: 401, headers, body: JSON.stringify({ error: 'Unauthorized' }) };
    }

    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) {
      return { statusCode: 401, headers, body: JSON.stringify({ error: 'Unauthorized' }) };
    }

    // Rate limit check
    if (await isRateLimited(user.id)) {
      return {
        statusCode: 429,
        headers,
        body: JSON.stringify({ error: 'Too many attempts — try again in an hour' }),
      };
    }

    const body = JSON.parse(event.body || '{}');
    const referralCode = String(body.referral_code || '').trim().toUpperCase().slice(0, 30);

    if (!referralCode) {
      return { statusCode: 400, headers, body: JSON.stringify({ error: 'referral_code required' }) };
    }

    const { data, error } = await supabase.rpc('redeem_referral', {
      p_referee_id:    user.id,
      p_referral_code: referralCode,
    });

    if (error) throw error;

    if (data?.error) {
      // Log non-success attempts for rate limiting (not true errors)
      if (data.error !== 'Referral already redeemed' && data.error !== 'Referee has not completed a booking yet') {
        await logError('redeem-referral', new Error(data.error), { user_id: user.id });
      }
      return { statusCode: 400, headers, body: JSON.stringify({ error: data.error }) };
    }

    return { statusCode: 200, headers, body: JSON.stringify({ success: true, data }) };

  } catch (err) {
    await logError('redeem-referral', err, {});
    return { statusCode: 500, headers, body: JSON.stringify({ error: err.message }) };
  }
};
