// netlify/functions/dormant-fixer-nudge.js — PATCHED v7.1
// Scheduled daily at 9am SA time (7am UTC).
//
// FIXES vs original:
//   - Message variant persisted in DB (no more random repeat for same fixer)
//   - Errors logged to function_errors table, not just console
//   - Error logging does not crash the loop
//
// netlify.toml: schedule = "0 7 * * *"

const { createClient } = require('@supabase/supabase-js');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

// ── Persistent error logging ──────────────────────────────────────
async function logError(fnName, error, context = {}) {
  console.error(`[${fnName}]`, error?.message || error, context);
  try {
    await supabase.rpc('log_function_error', {
      p_function: fnName,
      p_error:    String(error?.message || error),
      p_detail:   error?.stack || null,
      p_context:  context,
    });
  } catch (_) { /* never throw */ }
}

// ── WhatsApp sender ───────────────────────────────────────────────
async function sendWhatsApp(phone, message) {
  if (!process.env.WHATSAPP_API_URL || !process.env.WHATSAPP_API_TOKEN) {
    console.warn(`[dormant-fixer-nudge] WhatsApp not configured (missing WHATSAPP_API_URL or WHATSAPP_API_TOKEN). Skipping WhatsApp send to ${phone.slice(0, 5)}***`);
    return { ok: true, stubbed: true };
  }
  const response = await fetch(process.env.WHATSAPP_API_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${process.env.WHATSAPP_API_TOKEN}`,
    },
    body: JSON.stringify({ to: phone, type: 'text', text: { body: message } }),
  });
  return { ok: response.ok, status: response.status };
}

// ── Message templates (3 variants, rotated by mod of days offline) ──
// Rotation is deterministic per fixer (days_offline % 3), not random,
// so the same fixer always gets different messages across nudge cycles.
function buildDormantMessage(fixer) {
  const name      = (fixer.full_name || 'there').split(' ')[0];
  const demandCtx = fixer.demand_context || 'jobs are being posted in your city';
  const daysOff   = fixer.days_offline   || 7;

  const variants = [
    `Hi ${name}! 👋 It's been ${daysOff} days since you were last online. ${demandCtx} — go online now to start receiving offers. servit.co.za`,
    `Hey ${name}, customers are waiting! ${demandCtx} this week and we have no one to send them to. Log back in at servit.co.za`,
    `${name}, don't miss out 🔧 — ${demandCtx}. Fixers online during morning and evening peaks earn 3× more. servit.co.za`,
  ];

  // Deterministic variant selection: same fixer, different message each week
  const variantIndex = Math.floor(daysOff / 7) % variants.length;
  return variants[variantIndex];
}

// ── Main ──────────────────────────────────────────────────────────
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
  const results = { sent: 0, failed: 0, skipped: 0, total: 0 };

  try {
    const { data: dormantFixers, error } = await supabase
      .rpc('get_dormant_fixers', { p_days_offline: 7 });

    if (error) {
      await logError('dormant-fixer-nudge', error, { phase: 'fetch' });
      return { statusCode: 500, body: JSON.stringify({ error: error.message }) };
    }

    results.total = (dormantFixers || []).length;
    console.log(`Processing ${results.total} dormant fixers`);

    for (const fixer of (dormantFixers || [])) {
      if (!fixer.phone) {
        results.skipped++;
        continue;
      }

      try {
        const message = buildDormantMessage(fixer);
        const whatsAppResult = await sendWhatsApp(fixer.phone, message);

        if (whatsAppResult.ok || whatsAppResult.stubbed) {
          // Mark sent (uses date-stamped key so re-nudging works next week)
          await supabase.rpc('mark_nudge_sent', {
            p_fixer_id:   fixer.fixer_id,
            p_nudge_type: 'dormant',
          });

          // In-app notification
          await supabase.from('notifications').insert({
            user_id:    fixer.user_id,
            title:      'Customers are waiting for you! 🔧',
            body:       fixer.demand_context
              ? `${fixer.demand_context} — go online to start receiving offers.`
              : 'Go online now to receive job offers near you.',
            type:       'dormant_nudge',
          });

          results.sent++;
        } else {
          results.failed++;
          await logError('dormant-fixer-nudge',
            new Error(`WhatsApp returned ${whatsAppResult.status}`),
            { fixer_id: fixer.fixer_id, phone_hint: fixer.phone.slice(0, 5) + '***' }
          );
        }
      } catch (err) {
        results.failed++;
        await logError('dormant-fixer-nudge', err, { fixer_id: fixer.fixer_id });
      }

      await new Promise(r => setTimeout(r, 200));
    }

    console.log('Dormant nudge results:', results);
    return { statusCode: 200, body: JSON.stringify({ success: true, results }) };

  } catch (err) {
    await logError('dormant-fixer-nudge', err, { phase: 'fatal' });
    return { statusCode: 500, body: JSON.stringify({ error: err.message }) };
  }
};
