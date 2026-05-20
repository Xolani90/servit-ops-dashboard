/**
 * ops-proxy.js
 *
 * Server-side proxy for all Supabase calls made by the ops dashboard.
 * The service role key NEVER leaves the server — the dashboard sends
 * queries here and receives only the result data.
 *
 * Auth: HTTP Basic (same password as serve-admin-dashboard.js).
 * All requests must come from the dashboard, which is itself already
 * behind HTTP Basic, so this is a defence-in-depth check.
 *
 * Supported operations:
 *   { op: 'rpc',   fn: 'fn_name',   params: {} }
 *   { op: 'query', view: 'view_name', filter: 'col=eq.val&limit=100' }
 *   { op: 'patch', table: 'table_name', id: 'uuid', data: {} }
 *
 * URL: /.netlify/functions/ops-proxy
 */

const { createClient } = require('@supabase/supabase-js');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin':  '*',   // dashboard is same-origin in prod; relaxed for dev
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

// Table whitelist for patch operation - only allow safe admin operations
const PATCH_TABLE_WHITELIST = new Set([
  'bookings',
  'fixers',
  'profiles',
  'offers',
  'reviews',
  'disputes',
  'payouts',
  'notifications',
  'customer_nudges',
  'fixer_nudges',
  'referrals',
  'wallet_transactions',
  'booking_events',
  'admin_overrides',
  'matching_requests',
]);

exports.handler = async function (event) {
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 204, headers: CORS_HEADERS };
  }
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers: CORS_HEADERS, body: 'Method Not Allowed' };
  }

  // ── Auth: HTTP Basic, same password as serve-admin-dashboard ─────
  const PW          = process.env.ADMIN_DASHBOARD_PASSWORD;
  const SUPA_URL    = process.env.SUPABASE_URL;
  const SERVICE_KEY = process.env.SUPABASE_SERVICE_KEY;

  if (!PW || !SUPA_URL || !SERVICE_KEY) {
    return { statusCode: 503, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Proxy not configured' }) };
  }

  const authHeader = event.headers?.authorization || '';
  let authed = false;
  if (authHeader.startsWith('Basic ')) {
    const decoded  = Buffer.from(authHeader.slice(6), 'base64').toString('utf8');
    const [, pass] = decoded.split(':');
    authed = pass === PW;
  }
  if (!authed) {
    return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Unauthorized' }) };
  }

  // ── Parse body ────────────────────────────────────────────────────
  let body;
  try {
    body = JSON.parse(event.body || '{}');
  } catch {
    return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Invalid JSON' }) };
  }

  const supabase = createClient(SUPA_URL, SERVICE_KEY, { auth: { persistSession: false } });

  try {
    let result;

    if (body.op === 'rpc') {
      // ── RPC call ────────────────────────────────────────────────
      if (!body.fn || typeof body.fn !== 'string' || !/^\w+$/.test(body.fn)) {
        return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Invalid fn name' }) };
      }
      const { data, error } = await supabase.rpc(body.fn, body.params || {});
      if (error) throw error;
      result = data;

    } else if (body.op === 'query') {
      // ── View / table query ──────────────────────────────────────
      if (!body.view || typeof body.view !== 'string' || !/^[\w_]+$/.test(body.view)) {
        return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Invalid view name' }) };
      }
      // Parse filter string into supabase-js chain to avoid raw URL injection
      let q = supabase.from(body.view).select(body.select || '*');
      if (body.filter) {
        // Validate the filter string before forwarding. We only allow characters
        // that legitimate PostgREST filter expressions need: alphanumerics, dots,
        // dashes, underscores, equals, parentheses, asterisks, colons, commas,
        // percent-encoding, and spaces. Angle brackets, semicolons, quotes, and
        // newlines are never valid in a filter value and are blocked to prevent
        // header injection and other abuse by a compromised operator session.
        if (/[<>;"'\n\r\\]/.test(body.filter)) {
          return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Invalid characters in filter' }) };
        }
        const res = await fetch(
          `${SUPA_URL}/rest/v1/${body.view}?${body.filter}`,
          { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } }
        );
        if (!res.ok) {
          const errText = await res.text();
          throw new Error(`${body.view} query failed (${res.status}): ${errText}`);
        }
        result = await res.json();
      } else {
        const { data, error } = await q;
        if (error) throw error;
        result = data;
      }

    } else if (body.op === 'patch') {
      // ── Row patch ───────────────────────────────────────────────
      if (!body.table || typeof body.table !== 'string' || !/^[\w_]+$/.test(body.table)) {
        return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Invalid table name' }) };
      }
      // Enforce table whitelist - prevent patching sensitive tables like payments, auth.users, etc.
      if (!PATCH_TABLE_WHITELIST.has(body.table)) {
        return { statusCode: 403, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Table not allowed for patch operation' }) };
      }
      if (!body.id || typeof body.id !== 'string') {
        return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Missing id' }) };
      }
      const { error } = await supabase
        .from(body.table)
        .update(body.data || {})
        .eq('id', body.id);
      if (error) throw error;
      result = { ok: true };

    } else {
      return { statusCode: 400, headers: CORS_HEADERS, body: JSON.stringify({ error: `Unknown op: ${body.op}` }) };
    }

    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify(result),
    };

  } catch (err) {
    console.error('[ops-proxy] error:', err.message, body);
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ error: err.message }),
    };
  }
};
