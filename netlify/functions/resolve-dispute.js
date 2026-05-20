// ═══════════════════════════════════════════════════════════════
// resolve-dispute — Admin-only: resolve a DISPUTED booking
// POST /.netlify/functions/resolve-dispute
// Body: { dispute_id, outcome, admin_notes? }
// Outcomes: refund_customer | pay_fixer | split | dismissed
//
// This function requires the caller to be an admin (user_role='admin').
// The DB function resolve_dispute() verifies this independently.
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

const VALID_OUTCOMES = ['refund_customer', 'pay_fixer', 'split', 'dismissed'];

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: CORS };
  if (event.httpMethod !== 'POST') return { statusCode: 405, headers: CORS, body: 'Method Not Allowed' };

  try {
    const token = (event.headers.authorization || '').replace('Bearer ', '');
    if (!token) return { statusCode: 401, headers: CORS, body: JSON.stringify({ error: 'Unauthorized' }) };

    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    if (userError || !user) return { statusCode: 401, headers: CORS, body: JSON.stringify({ error: 'Invalid token' }) };

    // Verify admin role
    const { data: profile } = await supabase
      .from('profiles')
      .select('user_role')
      .eq('id', user.id)
      .maybeSingle();

    if (!profile || profile.user_role !== 'admin') {
      return { statusCode: 403, headers: CORS, body: JSON.stringify({ error: 'Admin access required' }) };
    }

    const { dispute_id, outcome, admin_notes } = JSON.parse(event.body || '{}');

    // Input length cap
    const safeAdminNotes = admin_notes ? String(admin_notes).slice(0, 1000) : null;

    if (!dispute_id) return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: 'Missing dispute_id' }) };
    if (!VALID_OUTCOMES.includes(outcome)) {
      return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: `outcome must be one of: ${VALID_OUTCOMES.join(', ')}` }) };
    }

    const { data: result, error } = await supabase.rpc('resolve_dispute', {
      p_dispute_id:  dispute_id,
      p_admin_id:    user.id,
      p_outcome:     outcome,
      p_admin_notes: safeAdminNotes,
    });

    if (error) return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: error.message }) };

    console.log(`Dispute ${dispute_id} resolved: ${outcome} by admin ${user.id}`);

    return {
      statusCode: 200,
      headers: { ...CORS, 'Content-Type': 'application/json' },
      body: JSON.stringify(result),
    };
  } catch (err) {
    console.error('resolve-dispute error:', err);
    return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: err.message }) };
  }
};
