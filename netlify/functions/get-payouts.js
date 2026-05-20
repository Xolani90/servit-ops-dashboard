// ═══════════════════════════════════════════════════════════════
// get-payouts — v5.2
// GET /.netlify/functions/get-payouts
//
// FIX: Was querying pro_profiles table (v4 name) — table doesn't
//      exist. Corrected to fixers. Also corrected pro_id → fixer_id
//      in the payouts query.
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

    // FIX: was querying pro_profiles — corrected to fixers
    const { data: fixer, error: fixerError } = await supabase
      .from('fixers')
      .select('id')
      .eq('user_id', user.id)
      .eq('status', 'approved')
      .maybeSingle();

    if (fixerError || !fixer) {
      return { statusCode: 403, headers: CORS, body: JSON.stringify({ error: 'Not a registered fixer' }) };
    }

    const { data: payouts, error } = await supabase
      .from('payouts')
      .select(`
        id, gross_amount, commission_amt, net_amount,
        status, hold_until, released_at, paid_at, created_at,
        booking:bookings(id, description, address, completed_at)
      `)
      .eq('fixer_id', fixer.id)   // FIX: was pro_id
      .order('created_at', { ascending: false })
      .limit(50);

    if (error) return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: error.message }) };

    const summary = payouts.reduce((acc, p) => {
      acc.total_gross  += Number(p.gross_amount)  || 0;
      acc.total_net    += Number(p.net_amount)    || 0;
      acc.pending_net  += p.status === 'held'     ? Number(p.net_amount) : 0;
      acc.released_net += p.status === 'released' ? Number(p.net_amount) : 0;
      acc.paid_net     += p.status === 'paid'     ? Number(p.net_amount) : 0;
      return acc;
    }, { total_gross: 0, total_net: 0, pending_net: 0, released_net: 0, paid_net: 0 });

    return {
      statusCode: 200,
      headers: { ...CORS, 'Content-Type': 'application/json' },
      body: JSON.stringify({ payouts, summary }),
    };

  } catch (err) {
    console.error('get-payouts error:', err);
    return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: err.message }) };
  }
};
