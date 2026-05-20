// netlify/functions/surge-signal.js — PATCHED v7.1
// GET /api/surge-signal?city=Pretoria&category=Plumbing
//
// FIXES vs original:
//   - CORS origin locked to ALLOWED_ORIGIN env var (not '*' in prod)
//   - Errors logged to function_errors table
//   - Input sanitisation: city/category max length enforced

const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

// In prod, set ALLOWED_ORIGIN=https://servit.co.za in Netlify dashboard.
// Falls back to '*' only if not set (safe for local dev).
const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN;
if (!ALLOWED_ORIGIN && process.env.NODE_ENV === 'production') {
  console.error('[surge-signal] ALLOWED_ORIGIN not set — CORS is open to all origins!');
}
const _corsOrigin = ALLOWED_ORIGIN || '*';

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

exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin':  _corsOrigin,
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Content-Type':                 'application/json',
    'Cache-Control':                'public, max-age=60', // surge data is fine to cache 60s
  };

  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers, body: '' };
  }

  try {
    const params   = event.queryStringParameters || {};
    const city     = String(params.city     || '').slice(0, 100).trim();
    const category = String(params.category || '').slice(0, 100).trim();

    if (!city) {
      return {
        statusCode: 400,
        headers,
        body: JSON.stringify({ error: 'city is required' }),
      };
    }

    const { data, error } = await supabase.rpc('get_surge_signal', {
      p_city:     city,
      p_category: category || null,
    });

    if (error) throw error;

    return { statusCode: 200, headers, body: JSON.stringify(data) };

  } catch (err) {
    await logError('surge-signal', err, {
      city:     (event.queryStringParameters || {}).city,
      category: (event.queryStringParameters || {}).category,
    });
    // Fail gracefully — never block the booking form
    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ is_surge: false, message: null }),
    };
  }
};
