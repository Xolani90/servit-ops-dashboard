// ═══════════════════════════════════════════════════════════════
// update-location — Fixer location + heartbeat
// POST /.netlify/functions/update-location
//
// Called by the fixer dashboard every 60 seconds via setInterval.
// Two jobs in one round-trip:
//
// IMPROVEMENT 1 (Geolocation): Saves fixer's current lat/lng so
//   match_fixers() can rank by Haversine distance instead of
//   city text equality.
//
// IMPROVEMENT 2 (Heartbeat): Updates last_seen_at so match_fixers()
//   can exclude fixers who closed their phone without toggling offline.
//   A fixer not seen for >3 minutes is treated as offline.
//
// Security: coordinates come from the browser's Geolocation API
//   (which requires explicit user permission), but we still validate
//   server-side that the values are plausible lat/lng ranges and that
//   the caller is an authenticated, approved fixer. A customer cannot
//   spoof a fixer's location.
//
// This is a fire-and-forget call — the frontend doesn't wait for the
// response. Failures are silently swallowed on the client.
//
// BUG 5 FIX (v8.6): Added DB-side rate limiting (120 calls / hour per
// user = every 30 s; generous for a 60 s heartbeat). Uses
// check_rate_limit() RPC added in v8_6_bugfixes.sql.
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
const RATE_LIMIT_ACTION   = 'update_location';
const RATE_LIMIT_MAX      = 120;    // max calls (every 30 s is the floor)
const RATE_LIMIT_WINDOW   = 3600;   // per hour (seconds)

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 204, headers: CORS_HEADERS };
  }

  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers: CORS_HEADERS, body: 'Method Not Allowed' };
  }

  try {
    // ── Authenticate ─────────────────────────────────────────────
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
      // Fail open — a DB error on rate check should not kill a heartbeat
    } else if (!allowed) {
      return {
        statusCode: 429,
        headers: { ...CORS_HEADERS, 'Retry-After': '3600' },
        body: JSON.stringify({ error: 'Rate limit exceeded. Try again later.' }),
      };
    }

    const { latitude, longitude } = JSON.parse(event.body || '{}');

    // ── Validate coordinates ──────────────────────────────────────
    // Accept heartbeat-only pings (no coords) — still updates last_seen_at.
    const hasCoords = (latitude != null && longitude != null);

    if (hasCoords) {
      // Sanity-check: valid lat/lng ranges
      if (
        typeof latitude  !== 'number' || isNaN(latitude)  ||
        typeof longitude !== 'number' || isNaN(longitude) ||
        latitude  < -90  || latitude  > 90  ||
        longitude < -180 || longitude > 180
      ) {
        return {
          statusCode: 400,
          headers: CORS_HEADERS,
          body: JSON.stringify({ error: 'Invalid coordinates' }),
        };
      }

      // Sanity-check: must be somewhere in southern Africa (rough bounding box)
      // Lat: -35 to -22, Lng: 16 to 33  (covers RSA + Namibia + Zim + Moz)
      // This prevents wildly wrong GPS readings (e.g. 0,0 on GPS failure)
      if (
        latitude  < -35 || latitude  > -22 ||
        longitude <  16 || longitude >  33
      ) {
        // Don't error — just update heartbeat without saving bad coords.
        // GPS sometimes returns 0,0 briefly on startup.
        return updateHeartbeatOnly(user.id);
      }
    }

    // ── Verify caller is an approved fixer ────────────────────────
    const { data: fixer, error: fixerError } = await supabase
      .from('fixers')
      .select('id, status')
      .eq('user_id', user.id)
      .maybeSingle();

    if (fixerError || !fixer) {
      return { statusCode: 403, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Not a registered fixer' }) };
    }

    if (fixer.status !== 'approved') {
      return { statusCode: 403, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Fixer not approved' }) };
    }

    // ── Update fixer record ───────────────────────────────────────
    const updateData = {
      last_seen_at: new Date().toISOString(),  // IMPROVEMENT 2: heartbeat
      updated_at:   new Date().toISOString(),
    };

    if (hasCoords) {
      updateData.latitude  = latitude;   // IMPROVEMENT 1: coordinates
      updateData.longitude = longitude;
    }

    const { error: updateError } = await supabase
      .from('fixers')
      .update(updateData)
      .eq('id', fixer.id);

    if (updateError) {
      console.error('Location update error:', updateError);
      return { statusCode: 500, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Update failed' }) };
    }

    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ok: true, has_coords: hasCoords }),
    };

  } catch (error) {
    console.error('update-location error:', error);
    return {
      statusCode: 500,
      headers: CORS_HEADERS,
      body: JSON.stringify({ error: error.message || 'Internal server error' }),
    };
  }
};

// Called when GPS gives an implausible reading — still keeps the fixer
// marked as "seen" so they're not excluded from matching.
async function updateHeartbeatOnly(userId) {
  await supabase
    .from('fixers')
    .update({ last_seen_at: new Date().toISOString(), updated_at: new Date().toISOString() })
    .eq('user_id', userId);

  return {
    statusCode: 200,
    headers: { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' },
    body: JSON.stringify({ ok: true, has_coords: false, note: 'Coordinates out of range, heartbeat only' }),
  };
}
