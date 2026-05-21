// ═══════════════════════════════════════════════════════════════════
// release-payouts — Belt-and-suspenders payout release trigger
// POST /.netlify/functions/release-payouts  (ops/admin manual trigger)
// Also called by Netlify scheduled function every 30 minutes.
//
// WHY THIS EXISTS:
//   pg_cron is the primary release mechanism (10_cron.sql).
//   pg_cron can fail silently if:
//     - The Supabase project is paused (free tier auto-pause after 7 days)
//     - The pg_cron extension is restarted during a DB upgrade
//     - The cron worker process crashes and misses a run
//
//   This Netlify function is a second, independent trigger that runs on
//   Netlify's scheduler (entirely separate infrastructure from Supabase).
//   If both fail simultaneously, something very unusual is happening and
//   ops will see both missing from the payout_runs audit table.
//
// SECURITY:
//   - Manual POST requires admin JWT (checked server-side)
//   - Scheduled invocation uses SUPABASE_SERVICE_KEY (no user token needed)
//   - release_due_payouts_v2() uses SKIP LOCKED — safe to call concurrently
//     from pg_cron and this function at the same time (no double-release)
//
// netlify.toml:
//   [[functions]]
//     name = "release-payouts"
//     schedule = "*/30 * * * *"
// ═══════════════════════════════════════════════════════════════════

const { createClient } = require('@supabase/supabase-js');
const { sendEmail } = require('./utils/email');

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

exports.handler = async (event) => {
  // Netlify Clockwork scheduled invocations include x-nf-event: schedule header
  const isScheduled = 
    event.headers?.['x-nf-event'] === 'schedule' ||
    event.headers?.['user-agent']?.includes('Netlify Clockwork') ||
    event.headers?.['user-agent']?.includes('Netlify');

  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 204, headers: CORS_HEADERS };
  }

  if (!isScheduled && event.httpMethod !== 'POST') {
    return { statusCode: 405, headers: CORS_HEADERS, body: 'Method Not Allowed' };
  }

  const supabase = createClient(
    process.env.SUPABASE_URL,
    process.env.SUPABASE_SERVICE_KEY,
    { auth: { persistSession: false } }
  );

  const triggerType = isScheduled ? 'netlify_scheduled' : 'manual_http';

  // For manual HTTP calls, require admin JWT
  if (!isScheduled) {
    const authHeader = event.headers && event.headers.authorization;
    if (!authHeader) {
      return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Unauthorized' }) };
    }

    const token = authHeader.replace('Bearer ', '');
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);
    if (userError || !user) {
      return { statusCode: 401, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Invalid token' }) };
    }

    const { data: profile } = await supabase
      .from('profiles')
      .select('user_role')
      .eq('id', user.id)
      .maybeSingle();

    if (!profile || profile.user_role !== 'admin') {
      return { statusCode: 403, headers: CORS_HEADERS, body: JSON.stringify({ error: 'Admin access required' }) };
    }
  }

  try {
    const { data: result, error } = await supabase.rpc('release_due_payouts_v2', {
      p_trigger: triggerType,
    });

    if (error) {
      console.error(`[release-payouts] DB error (${triggerType}):`, error.message);
      return {
        statusCode: 500,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
        body: JSON.stringify({ ok: false, error: error.message, trigger: triggerType }),
      };
    }

    console.log(`[release-payouts] ${triggerType}: released=${result?.released ?? 0}, amount=R${result?.total_amount ?? 0}`);

    // Send emails to fixers for released payouts
    if (result?.released_payouts && Array.isArray(result.released_payouts)) {
      for (const payout of result.released_payouts) {
        if (payout.fixer_email && payout.net_amount) {
          try {
            const html = `
              <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
                <h2 style="color: #333;">Your Servit payout has been released</h2>
                <p>Great news! Your payout has been released and is on its way to you.</p>
                <p><strong>Amount:</strong> R${payout.net_amount}</p>
                <p><strong>Job ID:</strong> ${payout.booking_id}</p>
                <p><strong>Estimated arrival:</strong> 1-3 business days</p>
                <p style="color: #666; font-size: 14px;">If you have any questions, please contact support.</p>
              </div>
            `;
            await sendEmail(payout.fixer_email, 'Your Servit payout has been released', html);
            console.log(`[release-payouts] Email sent to ${payout.fixer_email} for payout R${payout.net_amount}`);
          } catch (emailError) {
            console.error(`[release-payouts] Failed to send email to ${payout.fixer_email}:`, emailError.message);
          }
        }
      }
    }

    return {
      statusCode: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify(result),
    };
  } catch (err) {
    console.error(`[release-payouts] Unexpected error (${triggerType}):`, err.message);
    return {
      statusCode: 500,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ok: false, error: err.message }),
    };
  }
};
