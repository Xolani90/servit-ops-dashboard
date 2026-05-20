// netlify/functions/health-alert.js — NEW in v7.2
// Scheduled daily at 6am SA time (4am UTC).
// Calls get_health_alerts() and sends WhatsApp messages to admin_contacts
// when marketplace KPIs breach thresholds.
//
// Zero new infrastructure cost:
//   - Reuses existing WHATSAPP_API_URL + WHATSAPP_API_TOKEN env vars
//   - Falls back to console.log if WhatsApp isn't configured yet
//   - One extra Netlify scheduled function (free tier: 125k invocations/month)
//
// netlify.toml addition:
//   [[functions]]
//     name = "health-alert"
//     schedule = "0 4 * * *"

const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

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

async function sendWhatsApp(phone, message) {
  if (!process.env.WHATSAPP_API_URL || !process.env.WHATSAPP_API_TOKEN) {
    // No WhatsApp configured yet — log to Netlify console (visible in dashboard)
    console.warn(`[health-alert] WhatsApp not configured (missing WHATSAPP_API_URL or WHATSAPP_API_TOKEN). Skipping WhatsApp send to ${phone.slice(0, 5)}***`);
    return { ok: true, stubbed: true };
  }
  const res = await fetch(process.env.WHATSAPP_API_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${process.env.WHATSAPP_API_TOKEN}`,
    },
    body: JSON.stringify({ to: phone, type: 'text', text: { body: message } }),
  });
  return { ok: res.ok, status: res.status };
}

// SECURITY FIX (v8.6): Scheduled-only guard.
// When invoked via HTTP (not cron), require the same INTERNAL_SECRET used
// by sibling functions. This prevents anyone from triggering expensive
// scheduled operations on demand via a public HTTP call.
const INTERNAL_SECRET = process.env.INTERNAL_SECRET;

exports.handler = async (event) => {
  // Reject HTTP calls that don't carry the internal secret.
  // Netlify's own scheduler invokes with event.httpMethod === undefined.
  if (event && event.httpMethod) {
    const callerSecret = (event.headers || {})['x-internal-secret'];
    if (!INTERNAL_SECRET || callerSecret !== INTERNAL_SECRET) {
      return { statusCode: 401, body: JSON.stringify({ error: 'Unauthorized' }) };
    }
  }
  return _scheduledHandler();
};

async function _scheduledHandler() {
  try {
    // Get alerts for the past 7 days
    const { data: alerts, error: alertErr } = await supabase
      .rpc('get_health_alerts', { p_days: 7 });

    if (alertErr) {
      await logError('health-alert', alertErr, { phase: 'get_alerts' });
      return { statusCode: 500, body: JSON.stringify({ error: alertErr.message }) };
    }

    if (!alerts || alerts.length === 0) {
      console.log('[health-alert] All metrics healthy — no alerts to send.');
      return { statusCode: 200, body: JSON.stringify({ ok: true, alerts_sent: 0 }) };
    }

    // Get active admin contacts
    const { data: contacts } = await supabase
      .from('admin_contacts')
      .select('phone, label')
      .eq('active', true);

    if (!contacts || contacts.length === 0) {
      // No admin contacts configured — log prominently but don't crash
      console.warn('[health-alert] Alerts triggered but no admin_contacts configured. Add a row to admin_contacts table.');
      alerts.forEach(a => console.warn(' ALERT:', a.message));
      return { statusCode: 200, body: JSON.stringify({ ok: true, alerts_sent: 0, note: 'no_contacts_configured' }) };
    }

    const combinedMessage = alerts.map(a => a.message).join('\n\n');
    let sent = 0;

    for (const contact of contacts) {
      try {
        const result = await sendWhatsApp(contact.phone, combinedMessage);
        if (result.ok) sent++;
        else await logError('health-alert', new Error(`WhatsApp failed: ${result.status}`), { phone_hint: contact.phone.slice(0, 5) + '***' });
      } catch (err) {
        await logError('health-alert', err, { label: contact.label });
      }
    }

    console.log(`[health-alert] Sent ${sent} alert(s) for ${alerts.length} metric(s) breached.`);
    return {
      statusCode: 200,
      body: JSON.stringify({ ok: true, alerts_triggered: alerts.length, alerts_sent: sent }),
    };

  } catch (err) {
    await logError('health-alert', err, { phase: 'fatal' });
    return { statusCode: 500, body: JSON.stringify({ error: err.message }) };
  }
};
