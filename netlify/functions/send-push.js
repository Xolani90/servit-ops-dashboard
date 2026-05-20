// ═══════════════════════════════════════════════════════════════
// send-push — Send push notification to user
// POST /.netlify/functions/send-push
//
// SECURITY FIX: This endpoint is internal-only (called by other
// Netlify functions, never directly from the browser). It is
// protected by a shared INTERNAL_SECRET header so arbitrary
// callers cannot push notifications to any user ID they choose.
// Set INTERNAL_SECRET to a long random string in the Netlify
// dashboard and ensure all sibling functions send it.
// ═══════════════════════════════════════════════════════════════

const webpush = require('web-push');
const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY,
  { auth: { persistSession: false } }
);

const VAPID_PUBLIC_KEY = process.env.VAPID_PUBLIC_KEY;
const VAPID_PRIVATE_KEY = process.env.VAPID_PRIVATE_KEY;
const VAPID_SUBJECT = process.env.VAPID_SUBJECT || 'mailto:support@servit.co.za';

if (VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY) {
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
}

const INTERNAL_SECRET = process.env.INTERNAL_SECRET;

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') {
    return {
      statusCode: 204,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
      },
    };
  }

  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method Not Allowed' };
  }

  // SECURITY FIX: Reject any call missing the shared internal secret.
  // Fail closed — if INTERNAL_SECRET env var is unset, all calls are rejected.
  const callerSecret = (event.headers || {})['x-internal-secret'];
  if (!INTERNAL_SECRET || callerSecret !== INTERNAL_SECRET) {
    return { statusCode: 401, body: JSON.stringify({ error: 'Unauthorized' }) };
  }

  try {
    const { userId, title, body, data = {}, urgency = 'normal' } = JSON.parse(event.body || '{}');

    if (!userId || !title || !body) {
      return { statusCode: 400, body: JSON.stringify({ error: 'Missing required fields' }) };
    }

    // Get user's push subscriptions
    const { data: subscriptions, error: subError } = await supabase
      .from('push_subscriptions')
      .select('endpoint, keys')
      .eq('user_id', userId);

    if (subError || !subscriptions || subscriptions.length === 0) {
      return { statusCode: 200, body: JSON.stringify({ sent: 0 }) };
    }

    const payload = JSON.stringify({
      title,
      body,
      icon: '/icons/icon-192.png',
      badge: '/icons/icon-192.png',
      data: { ...data, url: '/' },
    });

    let sent = 0;
    const goneEndpoints = [];

    for (const sub of subscriptions) {
      try {
        await webpush.sendNotification(
          { endpoint: sub.endpoint, keys: sub.keys },
          payload,
          { urgency, TTL: 86400 }
        );
        sent++;
      } catch (err) {
        if (err.statusCode === 410 || err.statusCode === 404) {
          goneEndpoints.push(sub.endpoint);
        } else {
          console.error('Push send error:', err.statusCode, err.body);
        }
      }
    }

    // Clean up stale subscriptions
    if (goneEndpoints.length > 0) {
      await supabase
        .from('push_subscriptions')
        .delete()
        .in('endpoint', goneEndpoints);
    }

    return {
      statusCode: 200,
      headers: { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' },
      body: JSON.stringify({ sent, total: subscriptions.length }),
    };

  } catch (error) {
    console.error('Send push error:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: error.message || 'Internal server error' }),
    };
  }
};