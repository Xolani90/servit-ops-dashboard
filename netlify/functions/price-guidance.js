// price-guidance — v6.3
// Public endpoint — no auth required
// GET /.netlify/functions/price-guidance?category=Plumbing

const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: CORS };

  try {
    const category = event.queryStringParameters?.category;
    if (!category) {
      return { statusCode: 400, headers: CORS, body: JSON.stringify({ error: 'category required' }) };
    }

    const { data, error } = await supabase.rpc('get_price_guidance', { p_category: category });
    if (error) {
      console.error('Price guidance error:', error);
      return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: 'Failed to fetch price guidance' }) };
    }

    return {
      statusCode: 200,
      headers: { ...CORS, 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=3600' },
      body: JSON.stringify(data),
    };
  } catch (error) {
    console.error('price-guidance error:', error);
    return { statusCode: 500, headers: CORS, body: JSON.stringify({ error: 'Internal server error' }) };
  }
};
