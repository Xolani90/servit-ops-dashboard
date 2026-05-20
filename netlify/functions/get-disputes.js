// ═══════════════════════════════════════════════════════════════
// get-disputes — v5.2
// GET /.netlify/functions/get-disputes?status=open|resolved|all
//
// FIX: The select join referenced pro_profiles (v4 name) and
//      bookings.client_id (v4 name). Corrected to fixers and
//      bookings.customer_id to match the actual v5 schema.
// ═══════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

const CORS = {
  'Access-Control-Allow-Origin': process.env.URL || '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: CORS };
  if (event.httpMethod !== 'GET') return { statusCode: 405, headers: CORS, body: 'Method Not Allowed' };

  try {
    const token = (event.headers.authorization || '').replace('Bearer ', '');
    if (!token) return { statusCode: 401, headers: CORS, body: JSON.stringify({ error: 'Unauthorized' }) };

    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    if (userError || !user) return { statusCode: 401, headers: CORS, body: JSON.stringify({ error: 'Invalid token' }) };

    const { data: profile } = await supabase
      .from('profiles')
      .select('user_role')
      .eq('id', user.id)
      .maybeSingle();

    if (!profile || profile.user_role !== 'admin') {
      return { statusCode: 403, headers: CORS, body: JSON.stringify({ error: 'Admin access required' }) };
    }

    const status = event.queryStringParameters?.status || 'open';

    let query = supabase
      .from('disputes')
      .select(`
        id, reason, evidence_url, resolution, outcome, admin_notes,
        resolved_at, created_at, updated_at,
        booking:bookings(
          id, status, amount, address, description, category,
          customer:profiles!bookings_customer_id_fkey(full_name, email, phone),
          fixer:fixers!bookings_fixer_id_fkey(full_name, phone, rating)
        ),
        raised_by_profile:profiles!disputes_raised_by_fkey(full_name, email)
      `)
      .order('created_at', { ascending: false })
      .limit(100);

    if (status === 'open') {
      query = query.is('resolved_at', null);
    } else if (status === 'resolved') {
      query = query.not('resolved_at', 'is', null);
    }

    const { data: disputes, error } = await query;

    if (error) return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: error.message }) };

    return {
      statusCode: 200,
      headers: { ...CORS, 'Content-Type': 'application/json' },
      body: JSON.stringify({ disputes, count: disputes.length }),
    };

  } catch (err) {
    console.error('get-disputes error:', err);
    return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: err.message }) };
  }
};
