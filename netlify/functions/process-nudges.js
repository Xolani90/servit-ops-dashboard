// netlify/functions/process-nudges.js — PATCHED v7.2
// Scheduled — runs every hour.
// Processes fixer drip nudges + customer rebook prompts.
//
// v7.2 fixes vs v7.1:
//   FIX 3 — Push retry backpressure: nudges with 3+ push failures are skipped
//            and marked as permanently failed (failed_attempts column).
//            Prevents a broken push subscription silently consuming every run.
//
// netlify.toml: schedule = "0 * * * *"

const { createClient } = require('@supabase/supabase-js');
const webpush = require('web-push');

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

if (process.env.VAPID_PUBLIC_KEY && process.env.VAPID_PRIVATE_KEY) {
  webpush.setVapidDetails(
    'mailto:support@servit.co.za',
    process.env.VAPID_PUBLIC_KEY,
    process.env.VAPID_PRIVATE_KEY
  );
}

const MAX_PUSH_FAILURES = 3;

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
  } catch (_) { /* logging must never throw */ }
}

// ── Push helper ───────────────────────────────────────────────────
async function getPushSubscription(userId) {
  const { data } = await supabase
    .from('push_subscriptions')
    .select('endpoint, keys')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!data?.endpoint || !data?.keys) return null;
  return { endpoint: data.endpoint, keys: data.keys };
}

async function sendPush(userId, title, body, data = {}) {
  const sub = await getPushSubscription(userId);
  if (!sub) return { skipped: true, reason: 'no_subscription' };
  try {
    await webpush.sendNotification(sub, JSON.stringify({
      title, body, data, icon: '/icons/icon-192.png',
    }));
    return { ok: true };
  } catch (err) {
    // 410 = subscription expired/unsubscribed — delete it, don't retry
    if (err.statusCode === 410) {
      await supabase.from('push_subscriptions').delete().eq('user_id', userId);
      return { skipped: true, reason: 'subscription_expired' };
    }
    // FIX 3: surface the status code so callers can decide whether to increment failure count
    err.pushStatusCode = err.statusCode;
    throw err;
  }
}

// ── FIX 3: Increment failed_attempts on a fixer nudge row ─────────
// After MAX_PUSH_FAILURES the nudge is abandoned (marked failed_permanently).
// This requires the failed_attempts column added in 07_push_retry.sql.
async function recordFixerNudgeFailure(nudgeId) {
  try {
    await supabase.rpc('increment_nudge_failure', { p_nudge_id: nudgeId });
  } catch (_) { /* non-critical */ }
}

async function recordCustomerNudgeFailure(nudgeId) {
  try {
    await supabase.rpc('increment_customer_nudge_failure', { p_nudge_id: nudgeId });
  } catch (_) { /* non-critical */ }
}

// ── Process a fixer drip nudge ────────────────────────────────────
async function processFixerNudge(nudge) {
  const payload = nudge.payload || {};
  const title   = payload.title || 'Servit';
  const body    = payload.body  || '';

  // FIX 3: skip nudges that have already failed too many times
  if ((nudge.failed_attempts || 0) >= MAX_PUSH_FAILURES) {
    console.log(`[process-nudges] skipping fixer nudge ${nudge.nudge_id} — exceeded max failures`);
    return { skipped: true, reason: 'max_failures_exceeded' };
  }

  // Mark sent BEFORE pushing — prevents double-send if push crashes
  await supabase.rpc('mark_nudge_sent', {
    p_fixer_id:   nudge.target_id,
    p_nudge_type: nudge.nudge_type,
  });

  try {
    const result = await sendPush(nudge.user_id, title, body, {
      nudge_type: nudge.nudge_type,
      fixer_id:   nudge.target_id,
    });

    await supabase.from('notifications').insert({
      user_id: nudge.user_id, title, body,
      type: `drip_${nudge.nudge_type}`,
      related_id: nudge.target_id,
    });

    return result;
  } catch (err) {
    // FIX 3: push provider returned a 5xx — record the failure
    await recordFixerNudgeFailure(nudge.nudge_id);
    throw err;
  }
}

// ── Process a customer rebook nudge ──────────────────────────────
async function processCustomerRebookNudge(nudge) {
  const { fixer_name, fixer_id, category, booking_id } = nudge.payload || {};
  const userId = nudge.user_id;

  // FIX 3: skip nudges that have already failed too many times
  if ((nudge.failed_attempts || 0) >= MAX_PUSH_FAILURES) {
    console.log(`[process-nudges] skipping customer nudge ${nudge.nudge_id} — exceeded max failures`);
    return { skipped: true, reason: 'max_failures_exceeded' };
  }

  const title = `Book ${fixer_name || 'your fixer'} again?`;
  const body  = `Loved the ${category || 'service'} job? Rebook in one tap.`;

  // Mark sent BEFORE pushing
  await supabase
    .from('customer_nudges')
    .update({ sent_at: new Date().toISOString() })
    .eq('id', nudge.nudge_id);

  try {
    const result = await sendPush(userId, title, body, {
      action: 'rebook_prompt', booking_id, fixer_id, fixer_name, category,
    });

    await supabase.from('notifications').insert({
      user_id: userId, title, body,
      type: 'rebook_prompt', related_id: booking_id,
    });

    return result;
  } catch (err) {
    // FIX 3: record failure so this nudge is skipped after MAX_PUSH_FAILURES
    await recordCustomerNudgeFailure(nudge.nudge_id);
    throw err;
  }
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
  const results = { processed: 0, failed: 0, skipped: 0, abandoned: 0 };

  try {
    const { data: nudges, error } = await supabase
      .rpc('get_pending_nudges', { p_limit: 30 });

    if (error) {
      await logError('process-nudges', error, { phase: 'fetch' });
      return { statusCode: 500, body: JSON.stringify({ error: error.message }) };
    }

    // Process all nudges in parallel rather than serially with 100ms gaps.
    // The old serial loop took ≥3s for 30 nudges, risking Netlify's 10s timeout
    // when push provider latency is non-trivial. allSettled never throws, so one
    // failed push can't abort the rest of the batch.
    const BATCH = 10;  // cap concurrency to avoid overwhelming web-push provider
    const nudgeList = nudges || [];

    for (let i = 0; i < nudgeList.length; i += BATCH) {
      const batch = nudgeList.slice(i, i + BATCH);
      const settlements = await Promise.allSettled(
        batch.map(nudge =>
          nudge.nudge_source === 'customer'
            ? processCustomerRebookNudge(nudge)
            : processFixerNudge(nudge)
        )
      );

      for (let j = 0; j < settlements.length; j++) {
        const s = settlements[j];
        const nudge = batch[j];
        if (s.status === 'fulfilled') {
          const result = s.value;
          if (result?.skipped) {
            if (result.reason === 'max_failures_exceeded') results.abandoned++;
            else results.skipped++;
          } else {
            results.processed++;
          }
        } else {
          results.failed++;
          await logError('process-nudges', s.reason, {
            nudge_id:     nudge.nudge_id,
            nudge_type:   nudge.nudge_type,
            nudge_source: nudge.nudge_source,
            user_id:      nudge.user_id,
          });
        }
      }
    }

    console.log('process-nudges results:', results);
    return { statusCode: 200, body: JSON.stringify({ success: true, results }) };
  } catch (err) {
    await logError('process-nudges', err, { phase: 'fatal' });
    return { statusCode: 500, body: JSON.stringify({ error: err.message }) };
  }
};
